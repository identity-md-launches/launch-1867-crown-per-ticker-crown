# CROWN — a per-ticker crown registry and Uniswap v4 fee hook

Each ticker has one canonical token, the **king**. `CrownRegistry` maps
`ticker → {kingToken, beneficiary, reignStartedAt}`. `CrownHook` is a Uniswap v4 hook that takes a cut of every swap in
its pools and pays it to the current king's beneficiary **inside the same swap**. It is paid at the source: the hook
never holds or pools fees. Anyone can challenge a king with a bonded ETH stake-vote. If the challenger wins, the
registry switches to the new king after a timelock, and every later swap pays the new king.

Launch: Robinhood Chain (chain id 4663). The token is "Crown Demo" (CRWN), paired with native ETH, in a pool that uses
CrownHook. That token is the genesis king of ticker CRWN, and its beneficiary is the launch owner/payer wallet.

## Layout

| Path | What it is |
| --- | --- |
| `src/CrownRegistry.sol` | The registry and the challenge/stake/finalize/claim logic. It has no admin. |
| `src/CrownHook.sol` | The v4 hook. It creates its own `CrownRegistry` in its constructor. |
| `src/CrownToken.sol` | The launch token: "Crown Demo" / CRWN, 1,000,000,000 × 10^18 minted once to the deployer. |
| `src/CrownChallengerToken.sol` | The standing challenger candidate: a separate plain ERC-20 with the same name and symbol. |
| `src/libraries/Ticker.sol` | `ticker = keccak256(uppercase(symbol))`, plus a gas-capped `symbol()` reader. |
| `src/HookFlags.sol` | The v4 permission bits and CrownHook's flag set (`0x10CC`). |
| `script/DeployChallenger.s.sol` | Deploys the challenger candidate token. |
| `script/DeployCrown.s.sol` | Manual or rehearsal deployment of the hook at a mined flag address through the CREATE2 deployer. |
| `site/` | The static ticker page: `index.html`, `app.js`, `config.js`. |
| `test/` | Foundry tests: registry math, hook integration, end-to-end dethrone, token and scripts. |

## Compiler settings (pinned in `foundry.toml`, used for Sourcify verification)

| Setting | Value |
| --- | --- |
| solc | `0.8.26` |
| evm_version | `cancun` (v4-core uses transient storage; the hook uses `mcopy`) |
| optimizer | enabled, `runs = 200` |
| via_ir | `true` |
| bytecode_hash | `none` (CBOR metadata kept, no metadata hash) |
| Libraries | all internal (no linking) |

Dependencies are vendored as plain files under `lib/`: Uniswap `v4-core` (main), OpenZeppelin Contracts v5.1.0,
solmate (for v4-core's `PoolManager`, used in tests), and forge-std. To verify on Sourcify, submit the standard JSON
input from `forge build` (or use `forge verify-contract --verifier sourcify`) with the settings above.

Commands: `forge build`, `forge test`, `forge fmt --check`.

## CrownRegistry

* **Ticker:** `bytes32 ticker = keccak256(bytes(UPPERCASE(symbol)))`. For example, `keccak256("CRWN")`. A token can
  only be registered or challenge for a ticker if its own `symbol()` produces that ticker. Upper and lower case count
  as the same.
* `registerKing(ticker, token, beneficiary)`: the first registration for a ticker crowns that token. Anyone may call
  it. Later calls revert with `AlreadyCrowned`.
* `openChallenge(ticker, challengerToken)` payable, with exactly `BOND = 0.01 ether`. Conditions:
  * one live challenge per ticker;
  * the king must have reigned at least `MIN_REIGN = 7 days`;
  * `FAILED_COOLDOWN = 3 days` must have passed since the last failed challenge on that ticker;
  * the challenger token must differ from the king's token and must report the same ticker.

  The bond is the challenger's opening stake on the challenger side. **`msg.sender` becomes the challenger's
  beneficiary** if the challenge wins.
* `stake(challengeId, side)` payable: `side` is `0 = King` or `1 = Challenger`. It is open for
  `STAKING_WINDOW = 72 hours` from opening (`block.timestamp < stakingEndsAt`).
* `finalize(challengeId)`: anyone may call it from `stakingEndsAt + TIMELOCK (24 hours)` onward. The challenger wins
  iff `challengerStake > kingStake` **and** `kingStake + challengerStake >= QUORUM (0.05 ether)`. A tie, or a challenge
  below quorum, keeps the king, and the challenger side is then the losing side.
  * If the challenger wins, the king becomes `{challengerToken, challenger's beneficiary, now}`, and the registry emits
    `Dethroned` and `Crowned`.
  * If it fails, the cooldown starts and the registry emits `ChallengeFailed`.
* **Money:** let L be the losing side's total stake and W the winning side's.
  * `slash = L * 20%` (rounded down).
  * The losing stakers share `L − slash` pro rata (pull).
  * `slash / 2` goes to the winning stakers pro rata, on top of their full stake (pull).
  * `slash − slash/2` goes to the treasury `0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57`.
  * If the winning side has no stake (an unopposed challenge that fails quorum), the whole slash goes to the treasury.
  * Claims are paid pro rata over the stake not yet claimed, so the last claimer of each side receives the exact
    remainder. The payouts add up to the total staked, to the wei, and no winner ever gets less than their stake
    (fuzz-tested).
* `claim(challengeId)`: pays everything the caller is owed on both sides (pull). `claimable(id, who)` previews it.
* **Treasury share:** pushed at `finalize`. If the treasury cannot receive ETH, the amount is kept in `treasuryOwed`,
  and anyone can retry it with `payTreasury()`. The treasury can never block a resolution.
* **Public per-ticker totals:** `tickerTotals(ticker)` returns `activeChallengeId`, `cooldownUntil`, `challenges`,
  `dethrones`, `totalStaked` and `totalSlashed`. `challenges(id)` returns the full challenge state, including both
  stakes and all timestamps.
* **Events:** `Crowned`, `ChallengeOpened`, `Staked`, `Dethroned`, `ChallengeFailed`, `Slashed`, `Claimed`,
  `TreasuryPaid`.
* **No admin:** there are no owner or setter functions. The constructor takes no parameters, and every value above is
  a constant.

## CrownHook

Constructor: `(IPoolManager poolManager, address factory, address owner)`. The manifest writes these as
`"$poolManager"`, `"$factory"` and `"$owner"`. The constructor only stores them and runs `new CrownRegistry()`, which
makes no external calls. `registry()` returns the registry address.

### Permissions (configuration record)

```json
{
  "hook": "BaseHook", "name": "CrownHook", "pausable": false,
  "currencySettler": false, "safeCast": false, "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": false, "afterInitialize": true,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "access": "ownable (immutable owner, no transfer)", "info": { "license": "MIT" }
}
```

The address flags are `0x10CC` (`HookFlags.CROWN_HOOK`). The hook implements `IHooks` directly; it does not inherit
from v4-periphery. **Two permissions were added beyond the brief's `afterSwap`/`afterSwapReturnDelta`:
`beforeSwap` and `beforeSwapReturnDelta`.** The launch policy requires the fee to be settled in ETH, on the ETH side, for both
exact-input and exact-output swaps. `afterSwapReturnDelta` can only adjust the *unspecified* currency. When ETH is the
*specified* currency (an exact-input buy, or an exact-output sell), the cut has to be taken in `beforeSwap`. The
brief's `afterInitialize` is also the launch's required initialization callback.

### Pools

* `afterInitialize` records `poolId → {ticker, bps}`.
  * **Pool registration:** before opening a pool, the owner calls
    `configurePool(key, ticker, bps)` with `bps` between 0 and 500.
  * If a pool is opened without that call (the launch pool), it registers the ticker of its non-ETH token
    (`currency1`) at the default of **100 bps (1%)**.
  * Only the launch factory or the owner may initialize a pool on this hook. Anyone else is refused.
* **Genesis king:** at initialization, if the registry has no king for the pool's ticker and the pool's token reports
  that ticker, the hook calls `registry.registerKing(ticker, token, owner)`. The launch's CRWN pool therefore crowns
  CRWN, paying `$owner` (the launch payer), in the same transaction that deploys the hook and opens the pool. That
  leaves no window for front-running.

### The cut (the hook's fee on swaps)

* **Rate:** the pool's bps of the swap amount, measured in ETH. The CRWN pool uses 1%. This comes on top of the pool's
  1.25% LP fee (`pool.fee = 12500`).
* **Settlement:** always in **currency0**, which is native ETH on an ETH pool. It is never taken in the launch token.
  * Exact-input buy: 1% of the ETH input is taken before the swap. The trader pays exactly the input.
  * Exact-output buy: 1% of the ETH the swap needs is added to the trader's input.
  * Exact-input sell: 1% of the ETH output is withheld.
  * Exact-output sell: the pool pays out the requested ETH plus 1%, and the trader receives exactly what they asked
    for.
* **Where the ETH goes:** to `registry.beneficiaryOf(ticker)`, the current king's beneficiary. It is paid inside the
  same unlock: `poolManager.take(ETH, beneficiary, cut)` is offset by the hook's returned delta.
  * If the manager's ETH balance cannot cover the cut, or the transfer fails, the hook instead **mints an ERC-6909 ETH
    claim directly to the beneficiary** (`poolManager.mint`). The first case happens, for example, on a fresh manager
    whose pool was seeded with tokens only. The beneficiary redeems with `poolManager.setOperator(hook, true)` and then
    `hook.redeemClaim(ETH, amount)`.
  * Nothing is ever held by the hook.
* `crownPaid[ticker][currency]` is a public, cumulative counter covering both transfers and claims. Each payment emits
  `CrownPaid(ticker, poolId, beneficiary, currency, amount, asClaim)`.
* **The hook never blocks a swap:**
  * The registry read is gas-capped and wrapped in try/catch. So is the transfer, which runs through a self-call
    `payCrown` capped at 100k gas. The claim mint is gas-capped too.
  * If there is no king, the read fails, or both payments fail, the swap goes ahead **without** a cut, and the hook
    emits `CrownSkipped`.
  * The transfer's self-call reverts, undoing the transfer and anything the beneficiary did while receiving it, unless
    the manager's only new open delta is the hook's own debt for the cut. A beneficiary therefore cannot leave an
    unsettled delta that would revert the trader's unlock. Tested with a beneficiary that opens a debt and is then
    paid as a claim.
  * A beneficiary that rejects ETH or burns gas is paid as a claim instead, and the swap succeeds (tested).
* **Reentrancy:** all hook logic runs inside the PoolManager's unlock, and every callback checks
  `msg.sender == poolManager`. The only external calls during a swap are the registry read and the beneficiary
  payment, through `take` or `mint`. The hook keeps no balances that could be drained.
* **Liquidity:** the hook has no add or remove-liquidity callbacks. The launch factory's fee collect, a zero liquidity
  change, cannot be blocked (tested).

### Owner powers (`$owner`, immutable)

`configurePool` (pools not yet live only) and opening pools. The owner is also the genesis beneficiary. The owner has
no other powers. It cannot change a live pool's ticker or bps, cannot pause, and cannot withdraw anything.

## Launch parameters

| Item | Value |
| --- | --- |
| Chain | Robinhood Chain, id 4663 |
| Token | `CrownToken`: "Crown Demo", CRWN, 18 decimals, 1,000,000,000 tokens to the factory |
| Pair | native ETH (`currency0 = address(0)`) |
| Pool fee / tick spacing | 12500 / 60 |
| Hook | `CrownHook($poolManager, $factory, $owner)`, flags `0x10CC` |
| Hook cut | 100 bps (`DEFAULT_BPS`); maximum `MAX_BPS = 500` |
| Genesis king | ticker `keccak256("CRWN")` → launch token, beneficiary `$owner` (`0xb337afe64df8ae2ffc1656d503eb1477e7408d8c`) |
| Treasury | `0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57` (constant in the registry) |
| Bond / quorum | 0.01 ETH / 0.05 ETH |
| Min reign / window / timelock / cooldown | 7 days / 72 hours / 24 hours / 3 days |
| Slash | 20% of the losing side, split 50/50 between the winning stakers and the treasury |
| Hook gas caps | registry read 30k, transfer 100k, claim mint 60k |

Constants are named in source. Deployment and verification are done by IMD's launch pipeline, not by this
repository's scripts.

## After launch

1. **Site:** set `hook` in `site/config.js` to the deployed CrownHook address from the launch record. The registry
   address is read from `hook.registry()`. Then host `site/` as static files. Until then, the page shows a
   "not configured" message.
2. **Challenger candidate:** run
   `CHALLENGER_HOLDER=<wallet> forge script script/DeployChallenger.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast`.
   This deploys a second, distinct "Crown Demo"/CRWN ERC-20.
3. **End-to-end dethrone** (needs real time: 7 days of reign, then 72 hours plus 24 hours). `REG` is the registry
   address and `T` is `$(cast keccak CRWN)`.
   * `cast send $REG "openChallenge(bytes32,address)" $T <challengerToken> --value 0.01ether`. The sender becomes the
     new beneficiary if it wins.
   * `cast send $REG "stake(uint256,uint8)" <id> 1 --value 0.05ether` stakes on the challenger side. Use `0` for the
     king side.
   * After the window and timelock: `cast send $REG "finalize(uint256)" <id>`, then
     `cast send $REG "claim(uint256)" <id>` for each staker.
   * Any later swap in the CRWN pool pays the new beneficiary. Check with
     `cast call $REG "beneficiaryOf(bytes32)" $T` and `cast call <hook> "crownPaid(bytes32,address)" $T 0x0000000000000000000000000000000000000000`.

   The same flow runs in `test/CrownHook.t.sol::test_endToEnd_buyChallengeStakeFinalizeBuy`.
4. **Claims:** if a cut was paid as a claim (on a fresh manager, or when the beneficiary rejected ETH), the beneficiary
   redeems with `poolManager.setOperator(hook, true)` and then `hook.redeemClaim(0x0, amount)`. A beneficiary that
   cannot receive ETH should redeem to a different wallet by transferring the ERC-6909 claim first.

## Assumptions

* **Who may register:** `registerKing` is permissionless and first-come. For CRWN, the hook registers atomically at
  launch.
* **Matching symbols:** every king and challenger token must report the ticker's symbol through `symbol()` (a string).
* **Challenger beneficiary:** the challenger's beneficiary is the wallet that opened the challenge, because the brief's
  `openChallenge(ticker, challengerToken)` has no beneficiary argument.
* **Bond:** the bond is counted as the challenger's own stake, so it is refunded or slashed like any other stake.
* **Failed challenges:** a challenge that fails because of the quorum or a tie slashes the challenger side as the
  losing side, and starts the 3-day cooldown.
* **Fee currency:** the cut is taken in currency0. On an ETH pool that is always ETH. A pool with two ERC-20 tokens
  would pay in currency0, and its `crownPaid` is tracked in that currency.
* **Token-only seeding:** on a pool seeded with tokens only, early buys may be paid as ETH claims rather than
  transfers, as described above.

## What the brief asked that this repository does not do

* **Deployment:** it does not deploy or broadcast anything. IMD's launch pipeline deploys the token and the hook (which
  creates the registry) on Robinhood Chain. The challenger token is deployed after launch with the script above.
* **Live demo:** the end-to-end dethrone needs 7 days plus 96 hours of real time on chain. It is fully exercised in the
  Foundry tests. On chain, it is an after-launch procedure (step 3).

## Operational responsibilities

* The `$owner` wallet receives the CRWN cut until it is dethroned. It must be able to receive ETH, or else redeem
  claims.
* Someone must call `finalize` after each timelock, and each staker must call `claim`. Nothing happens automatically.
* The site needs the hook address set after launch.
* Tests passing is not an audit. This code moves other people's ETH in every swap and holds stakes. **An independent
  adversarial review is required before real funds use it.**

## Tests

* `test/CrownRegistry.t.sol`:
  * bond exactness; reign, window and timelock boundaries; one live challenge per ticker; cooldown;
  * the slash split exact to the wei, for both a win and a quorum failure; ties; unopposed challenges;
    stakers on both sides;
  * claim failure paths; claim reentrancy; a treasury that rejects ETH;
  * a conservation fuzz test (every wei staked is paid out, and winners get at least their stake).
* `test/CrownHook.t.sol`:
  * permissions and address flags; the initializer gate; genesis crowning; callbacks refusing non-manager callers;
    `configurePool` rules;
  * the cut on an exact-input and exact-output buy and an exact-input and exact-output sell, plus a fuzz test;
  * claim fallback and redeem on a fresh, token-only-seeded manager;
  * beneficiaries that reject ETH, burn gas, or open a debt; no king; 0 bps; the factory's zero-liquidity fee collect;
  * **the v4 end-to-end test: buy → challenge → stake → finalize → buy**, asserting that the fee recipient changed
    and that `crownPaid` equals the transfers.
* `test/CrownToken.t.sol`:
  * the token's supply and transfers; the challenger deploy script; the hook deploy script's salt mining.
