# Crown ticker frontend

The production website is `../dist/`. It is a static Vite + React + TypeScript application with local assets, relative URLs, hash-based ticker selection, wagmi wallet discovery and viem contract calls. There is no backend and no credential or relay requirement.

## Build and preview

Use Node 22.23 or a compatible newer version. From the repository root:

```sh
npm --prefix site ci
npm --prefix site run typecheck
npm --prefix site run build
npm --prefix site run preview -- --host 127.0.0.1
```

Deploy the complete `dist/` directory as plain files, including `crown-config.json`, `abi/`, `wallets/` and `assets/`. No rewrite rule is needed. The export was exercised under `/preview/`, not only the origin root. The build's chunk-size advisory is informational; the Coinbase SDK is loaded on demand and the complete export is below 1 MiB.

Source and lockfile live under `site/`, leaving the existing Foundry settings and dependencies intact. Dependency directories and package caches are not submission artifacts.

## Deployment configuration

No `.imd/reads/deployment.json` or `.imd/reads/network.json` was supplied for this assignment. The delivered app therefore states **Awaiting deployment**, displays no invented king, balances or addresses, and disables transactions. Connecting a wallet does not create a deployment. Live Robinhood transactions and a deployed end-to-end demo have not been claimed.

`public/crown-config.json` is the single public configuration source before a workflow handoff exists. It contains Robinhood Chain 4663, its public RPC, explorer, native currency, an empty `contracts` array and ABI paths. `src/config.ts` validates and loads that JSON at runtime. The public network metadata follows [Robinhood's official deployment documentation](https://docs.robinhood.com/chain/deploy-smart-contracts/); the public RPC chain ID was checked on 2026-10-15.

After launch, an operator can supply actual `CrownHook` and optional `CrownChallengerToken` entries in `contracts`, each with `name` and the real `address`, then rebuild. Never insert an example, zero or test address. The application reads the registry, PoolManager and owner from the hook and checks contract code and chain identity before enabling transactions. An explicit registry address, when present, must match the hook's registry.

When workflow input files are present, `scripts/export.mjs` automatically generates `dist/imd-deployment.json`. It preserves the handoff's identifiers, full contract set, addresses and pool key; copies the network and wallet-add-chain objects unchanged; verifies canonical Keccak ABI hashes; and inventories every other exported file with SHA-256. `crown-config.json` then selects that manifest, which supplies runtime deployment addresses and chain configuration. No manifest is fabricated when the handoff is absent. Rebuild after changing any exported file so the hash inventory remains current. `tests/export.mjs` exercises this path using a fixture isolated under `test/scratch/` and rejects a tampered ABI.

The network shape consumed by the runtime is `name`, `rpcUrls` (array), `explorer` or `explorerUrl` (URL), `nativeCurrency`, `testnet`, plus the optional `uniswapV4` object. The deployed hook's PoolManager must agree with `network.uniswapV4.poolManager` when supplied. This ticker assignment has no trading or liquidity execution controls; the exported app explains that absence, including the missing vetted Uniswap configuration in this delivery. It never invents a router, quoter or Permit2.

## Contract interface and behavior

| Control | Contract action | Preconditions / important effect |
| --- | --- | --- |
| Register the first king | `CrownRegistry.registerKing` | Unregistered ticker, matching token symbol, nonzero beneficiary |
| Open challenge | `CrownRegistry.openChallenge` | Distinct matching-symbol token, seven-day reign, no live challenge, expired cooldown, caller is not the sitting beneficiary; exactly 0.01 ETH |
| Back either side | `CrownRegistry.stake` | Active 72-hour window, strictly positive amount with at most 18 decimals; side 0 or 1 |
| Finalize challenge | `CrownRegistry.finalize` | Window and 24-hour timelock ended; permissionless |
| Claim stake refund | `CrownRegistry.claim` | Selected challenge belongs to the ticker and connected wallet has claimable ETH |
| Authorize / revoke claim redemption | `PoolManager.setOperator` | Explicit separate approval covering all of this wallet's claim currencies |
| Redeem ETH claims | `CrownHook.redeemClaim` | Confirmed operator permission and sufficient native-currency claims |
| Retry treasury payment | `CrownRegistry.payTreasury` | Nonzero outstanding treasury credit; fixed recipient |
| Configure a future native ETH pool | `CrownHook.configurePool` | Owner-only panel; 0–500 bps; fee 12500, spacing 60, actual hook; live pools cannot change |

Internal callbacks and `payTreasuryIsolated` are not visitor actions. The latter accepts only the registry itself.

The canonical ticker is `keccak256(uppercase(symbol))`. This UI accepts 1–32 ASCII letters, numbers, periods, underscores and hyphens. Unusual symbols outside that set remain usable directly through the registry. The opening wallet becomes the challenger beneficiary. The 0.01 ETH bond counts toward its stake. A challenge below quorum or tied in stake keeps the king. Stakes are locked until finalization and losing stakes lose 20%; exact claimable amounts come from the contract, including its remainder policy.

The page reports native ETH `crownPaid`, total stakes, total slashes, challenges and dethrones. `crownPaid` includes direct transfers **and** PoolManager claims, as implemented by the accepted hook. No USD conversion is fabricated. ERC-20 fee claims for non-native pools are outside this launch's UI. Historical refunds can be retrieved by challenge number; this app does not run an indexer or scan an unlimited event history.

## Wallets and transaction handling

The first-screen wallet control discovers extensions with EIP-6963, offers Coinbase Wallet / Smart Wallet, and provides MetaMask, Coinbase, Rabby and Phantom mobile browser links. Coinbase's SDK is bundled locally. Rabby's URL uses its [open-dapp command](https://github.com/RabbyHub/rabby-mobile/blob/develop/apps/mobile/src/hooks/universalLink.ts), verified against its public source. Wallet marks come from RainbowKit 2.2.11; attribution is in `WALLET-ICONS-LICENSE.txt`.

Wrong-chain wallets get one switch control. Error 4902 or an unknown-chain response invokes `wallet_addEthereumChain` before retrying the switch. The runtime uses the supplied wallet-add-chain object when present. A native `<dialog>` provides modal focus isolation, Escape, close control and return focus; the wallet sheet also closes on its backdrop.

Reads poll every five seconds while the page is visible. All per-ticker values in one snapshot use the same block. Public RPCs are tried first, with the connected wallet as a fallback only on the correct chain. Failed reads and snapshots older than 30 seconds block transactions.

Each action validates its inputs, simulates the call, estimates gas, checks available ETH, presents a review with network, amount, recipient and contract, rechecks account/chain, simulates again, and requests the visitor's signature. An independent action lock covers signing and receipt confirmation. Receipt failures keep the action locked and expose **Check confirmation**; they do not silently permit a duplicate send. Replacements and cancellations are reported. Receipt status is held in page memory, so after a reload the visitor should check their wallet/explorer before repeating an uncertain action. Confirmed actions refetch contract state.

## ABI updates

The five raw JSON arrays in `public/abi/` come from this repository's compiled contracts, not handwritten function strings. After any Solidity change:

```sh
forge build --offline
node site/scripts/abis.mjs
npm --prefix site run build
```

The root README records the pinned Solidity settings. A deployment handoff with an ABI hash that differs from these exports is refused; do not bypass that check.

## Validation

```sh
IMD_PLAYWRIGHT="$HOME/.imd-taste/node_modules/playwright/index.mjs" npm --prefix site test
IMD_PLAYWRIGHT="$HOME/.imd-taste/node_modules/playwright/index.mjs" node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste
```

`IMD_PLAYWRIGHT` names a Playwright module installed outside the repository, at the location the design probe itself documents (`npm install --prefix "$HOME/.imd-taste" playwright@1`, then `playwright install chromium`); both scripts fall back to any Playwright they can resolve. On another development machine, adjust the Playwright import to an installed copy and use its browser installation. Tests serve the production export themselves, use mocked RPC/EIP-6963 providers, and close the server and browser when done. They do not transmit transactions. Screenshots and fixture files are written only to `test/scratch/` and are not delivered.

See `../VALIDATION.md` for executed commands, results and untested live behavior, `../DESIGN.md` for the implemented design system, and `../REVIEW.md` for the limited treasury payout change and static-analysis dispositions. The optional social asset generator is `scripts/social.mjs`; its code-native SVG source is `design/social.svg`. The delivered PNG needs no runtime renderer.
