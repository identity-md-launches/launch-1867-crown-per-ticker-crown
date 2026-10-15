// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CrownRegistry} from "./CrownRegistry.sol";
import {Ticker} from "./libraries/Ticker.sol";

/// @title CrownHook
/// @notice A Uniswap v4 hook that skims a cut of every swap in its pools and pays it, inside the same swap, to the
/// current king's beneficiary for the pool's ticker in CrownRegistry. Fees are never held by the hook.
/// @dev The cut is always taken in currency0 (native ETH on an ETH pool): from the input when currency0 is the
/// specified side (beforeSwap + beforeSwapReturnDelta), otherwise from the unspecified side (afterSwap +
/// afterSwapReturnDelta). It is paid with `poolManager.take` to the beneficiary when the manager holds enough of the
/// currency, otherwise (or if the transfer fails) as an ERC-6909 claim minted straight to the beneficiary. If the
/// registry read or both payments fail, the swap proceeds without a cut: the hook never reverts a swap for a payment
/// failure. A cut reserved in beforeSwap is charged on the amount the swapper specified, which v4 only treats as an
/// upper bound: afterSwap therefore checks that the pool filled that request in full and refuses a partial fill
/// (`PartialFill`), so a swapper is never charged for more than it traded. Shapes charged in afterSwap use the
/// realised delta and are never affected.
contract CrownHook is IHooks, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    struct PoolConfig {
        bytes32 ticker;
        uint16 bps;
        bool set;
    }

    uint16 public constant DEFAULT_BPS = 100;
    uint16 public constant MAX_BPS = 500;
    uint256 internal constant BPS = 10_000;
    /// @dev Gas for the registry read and for the beneficiary transfer, so a hostile beneficiary cannot eat the swap.
    uint256 internal constant REGISTRY_GAS = 30_000;
    uint256 internal constant TRANSFER_GAS = 100_000;
    uint256 internal constant MINT_GAS = 60_000;
    uint256 internal constant BALANCE_GAS = 30_000;
    /// @dev Transient slot holding, between beforeSwap and afterSwap, the currency0 amount the pool has to fill for
    /// the cut reserved in beforeSwap to be the right one. Zero when nothing was reserved.
    bytes32 internal constant EXPECTED_FILL_SLOT = keccak256("CrownHook.expectedFill");

    IPoolManager public immutable poolManager;
    /// @notice The registry this hook pays from, created with the hook so it exists before any pool can open.
    CrownRegistry public immutable registry;
    /// @notice The launch factory, allowed to open pools on this hook.
    address public immutable factory;
    /// @notice The deployer: may configure and open further pools, and is the genesis beneficiary. No other powers.
    address public immutable owner;

    mapping(PoolId => PoolConfig) public pendingConfig;
    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice Cumulative cut paid to the kings of `ticker`, per currency.
    mapping(bytes32 ticker => mapping(Currency => uint256)) public crownPaid;

    event PoolConfigured(PoolId indexed poolId, bytes32 indexed ticker, uint16 bps);
    event PoolRegistered(PoolId indexed poolId, bytes32 indexed ticker, uint16 bps);
    event CrownPaid(
        bytes32 indexed ticker,
        PoolId indexed poolId,
        address indexed beneficiary,
        Currency currency,
        uint256 amount,
        bool asClaim
    );
    event CrownSkipped(bytes32 indexed ticker, PoolId indexed poolId, uint256 amount);

    error NotPoolManager();
    error NotSelf();
    error NotOwner();
    error NotAuthorizedInitializer();
    error HookNotImplemented();
    error ZeroAddress();
    error BpsTooHigh();
    error WrongHook();
    error PoolAlreadyLive();
    error ZeroTicker();
    error DeltaMismatch();
    /// @notice The pool's ticker is already held by a different token: opening this pool without `configurePool`
    /// would pay a squatter. Configure the pool explicitly, or challenge for the ticker first.
    error TickerTaken();
    /// @notice The specified amount exceeds what a v4 pool can ever fill, so no cut on it could be right.
    error AmountTooLarge();
    /// @notice The pool filled less than the specified amount the cut was reserved on (price limit or liquidity).
    error PartialFill();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address factory_, address owner_) {
        if (address(poolManager_) == address(0) || factory_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        factory = factory_;
        owner = owner_;
        registry = new CrownRegistry();
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ owner

    /// @notice Sets the ticker and cut (0..500 bps) a pool registers with, before it is initialized. Pools opened
    /// without this register the ticker of their non-ETH token (currency1) at DEFAULT_BPS.
    function configurePool(PoolKey calldata key, bytes32 ticker, uint16 bps) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (bps > MAX_BPS) revert BpsTooHigh();
        if (ticker == bytes32(0)) revert ZeroTicker();
        PoolId id = key.toId();
        if (poolConfig[id].set) revert PoolAlreadyLive();
        pendingConfig[id] = PoolConfig(ticker, bps, true);
        emit PoolConfigured(id, ticker, bps);
    }

    // ------------------------------------------------------------------ hook callbacks

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory && sender != owner) revert NotAuthorizedInitializer();
        PoolId id = key.toId();
        PoolConfig memory cfg = pendingConfig[id];
        address token = Currency.unwrap(key.currency1);
        bool derived = !cfg.set;
        if (derived) {
            cfg = PoolConfig(Ticker.ofToken(token), DEFAULT_BPS, true);
            // A pool whose token has no readable string symbol would be live for ever with no ticker and no cut.
            if (cfg.ticker == bytes32(0)) revert ZeroTicker();
        }
        delete pendingConfig[id];
        poolConfig[id] = cfg;

        // Genesis: the pool's own token is crowned for its ticker, paying the owner, if nobody holds it yet.
        if (cfg.ticker != bytes32(0) && registry.beneficiaryOf(cfg.ticker) == address(0)) {
            try registry.registerKing(cfg.ticker, token, owner) {} catch {}
        }
        // A pool opened on its token's own ticker without explicit configuration must be that ticker's king: when the
        // ticker was registered first by someone else, the pool would pay the squatter from its first swap.
        if (derived) {
            (address kingToken,,) = registry.king(cfg.ticker);
            if (kingToken != token) revert TickerTaken();
        }
        emit PoolRegistered(id, cfg.ticker, cfg.bps);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        // currency0 is the specified side for exact-input zeroForOne and exact-output oneForZero swaps.
        if (params.zeroForOne != exactInput) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (amount > type(uint128).max) {
            // The pool can never fill such a request; it is only bounded by the price limit. Refuse it when this
            // pool charges a cut, so an oversized request is not a fee-free trade.
            PoolConfig memory cfg = poolConfig[key.toId()];
            if (cfg.ticker != bytes32(0) && cfg.bps != 0) revert AmountTooLarge();
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 paid = _crown(key, amount);
        // The pool is asked for the request net of the cut (exact input) or plus the cut (exact output); afterSwap
        // checks it filled exactly that, so the cut reserved here is the cut on what was actually traded.
        if (paid != 0) _setExpectedFill(exactInput ? amount - paid : amount + paid);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(paid)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool exactInput = params.amountSpecified < 0;
        int128 amount0 = delta.amount0();
        uint256 amount = amount0 < 0 ? uint256(-int256(amount0)) : uint256(int256(amount0));
        if (params.zeroForOne == exactInput) {
            // Charged in beforeSwap on the specified amount: the pool must have filled it in full.
            uint256 expected = _takeExpectedFill();
            if (expected != 0 && amount != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 paid = _crown(key, amount);
        return (IHooks.afterSwap.selector, int128(int256(paid)));
    }

    // ------------------------------------------------------------------ payment

    /// @dev Computes the cut on `amount` of currency0 (at most uint128.max, so the cut fits an int128) and pays it to
    /// the king. Returns what was paid, which the caller reports as the hook's delta: the payment left the hook owing
    /// exactly that, so the books balance.
    function _crown(PoolKey calldata key, uint256 amount) internal returns (uint256) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (cfg.ticker == bytes32(0) || cfg.bps == 0) return 0;
        uint256 cut = amount * cfg.bps / BPS;
        if (cut == 0) return 0;

        address beneficiary;
        try registry.beneficiaryOf{gas: REGISTRY_GAS}(cfg.ticker) returns (address b) {
            beneficiary = b;
        } catch {}
        if (beneficiary == address(0)) {
            emit CrownSkipped(cfg.ticker, id, cut);
            return 0;
        }

        Currency currency = key.currency0;
        bool asClaim;
        bool paid;
        if (_managerHolds(currency, cut)) {
            try this.payCrown{gas: TRANSFER_GAS}(currency, beneficiary, cut) {
                paid = true;
            } catch {}
        }
        if (!paid) {
            try poolManager.mint{gas: MINT_GAS}(beneficiary, currency.toId(), cut) {
                paid = true;
                asClaim = true;
            } catch {}
        }
        if (!paid) {
            emit CrownSkipped(cfg.ticker, id, cut);
            return 0;
        }
        crownPaid[cfg.ticker][currency] += cut;
        emit CrownPaid(cfg.ticker, id, beneficiary, currency, cut, asClaim);
        return cut;
    }

    /// @dev Whether the manager holds at least `amount` of `currency`, read without letting a token that reverts on
    /// `balanceOf` revert the swap: an unreadable balance counts as too small, and the cut becomes a claim.
    function _managerHolds(Currency currency, uint256 amount) internal view returns (bool) {
        if (currency.isAddressZero()) return address(poolManager).balance >= amount;
        (bool ok, bytes memory data) = Currency.unwrap(currency).staticcall{gas: BALANCE_GAS}(
            abi.encodeWithSignature("balanceOf(address)", address(poolManager))
        );
        return ok && data.length >= 32 && abi.decode(data, (uint256)) >= amount;
    }

    /// @notice Transfers the cut to the beneficiary through the PoolManager. Callable only by this hook.
    /// @dev Reverts, undoing the transfer and anything the beneficiary did while receiving it, unless the only change
    /// to the manager's transient state is this hook's debt for the cut: the open deltas, the synced currency and its
    /// reserves must all be as they were. A beneficiary that leaves an unsettled delta, or re-syncs the manager
    /// under a router that synced before the swap, would otherwise make the swapper's whole unlock revert.
    function payCrown(Currency currency, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (poolManager.currencyDelta(address(this), currency) != 0) revert DeltaMismatch();
        uint256 countBefore = poolManager.getNonzeroDeltaCount();
        Currency syncedBefore = poolManager.getSyncedCurrency();
        uint256 reservesBefore = poolManager.getSyncedReserves();
        poolManager.take(currency, to, amount);
        if (
            poolManager.getNonzeroDeltaCount() != countBefore + 1
                || poolManager.currencyDelta(address(this), currency) != -int256(amount)
                || !(poolManager.getSyncedCurrency() == syncedBefore)
                || poolManager.getSyncedReserves() != reservesBefore
        ) revert DeltaMismatch();
    }

    function _setExpectedFill(uint256 amount) internal {
        bytes32 slot = EXPECTED_FILL_SLOT;
        assembly ("memory-safe") {
            tstore(slot, amount)
        }
    }

    function _takeExpectedFill() internal returns (uint256 amount) {
        bytes32 slot = EXPECTED_FILL_SLOT;
        assembly ("memory-safe") {
            amount := tload(slot)
            tstore(slot, 0)
        }
    }

    /// @notice Redeems `amount` of the caller's ERC-6909 claims on `currency` (minted when a cut could not be
    /// transferred) for the currency itself. The caller must first `poolManager.setOperator(hook, true)`.
    function redeemClaim(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(msg.sender, currency, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address holder, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        poolManager.burn(holder, currency.toId(), amount);
        poolManager.take(currency, holder, amount);
        return "";
    }

    // ------------------------------------------------------------------ not enabled

    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
