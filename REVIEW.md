# Scoped implementation review

The revision round that followed the independent review (partial-fill and oversized-amount refusal, synced-currency checks in `payCrown`, the self-challenge and undefended-flip rules, and the pool-opening refusals) is recorded in `VALIDATION.md` under "Revision round" and answered finding by finding in `.imd-responses.json`; the rules themselves are in `README.md`. Slither could not be re-run for it on this worker. A second round answered the re-raised self-challenge finding (a one-wei king-side defence bought seven days of protection for free) by splitting the reign clock from the challenge gate: `reignStartedAt` restarts on every flip, `challengeableAt` moves only for a defence of at least `MIN_DEFENCE`; see `VALIDATION.md`, "Second revision round".

This records the frontend implementer's checks and the small Solidity change needed by the required Foundry/Slither profile. It is not a claim of an independent security audit or a deployed-chain review. The accepted registry economics, hook fee routing, permissions, token behavior and deployment model are retained.

## Treasury fallback change

The initial high-only Slither run reported `reentrancy-eth` in `CrownRegistry._payTreasury`: the failed native transfer branch wrote `treasuryOwed` after the external call. Both callers were already guarded by `nonReentrant`; no successful exploit of the accepted implementation was demonstrated. The finding nevertheless failed the required static-analysis gate.

`src/CrownRegistry.sol:301` now performs the balance update and transfer within `payTreasuryIsolated`, a self-call-only boundary. It zeroes the credit before the transfer and reverts on rejection, which restores the credit atomically. `_payTreasury` catches that revert without a state write after the transfer. The existing guarded `finalize` and permissionless `payTreasury` entry points retain their behavior. There is no new admin privilege, alternative recipient or withdraw path.

The added registry regression test rejects an external call to the helper, retries a rejecting treasury twice without losing credit, then succeeds once and proves an extra retry cannot pay again. Existing treasury failure, exact-wei payout, conservation and hook integration tests also pass. The frontend ABI export includes the helper but presents only `payTreasury` as a user action.

The subsequent high-only Slither run reports **0 results**. No detector suppressions or build-setting changes were added.

## Remaining medium static-analysis results

The medium-inclusive run reports 12 results (three detector families) and exits nonzero because of those medium findings. These are retained and justified here; this is not reported as a clean medium run.

| Detector / locations | Disposition |
| --- | --- |
| `divide-before-multiply`, `lib/v4-core/src/libraries/CustomRevert.sol:91` | Intentional ceiling-to-32-byte alignment of revert-data length. This is memory sizing, not stake or fee math. Vendored dependency is protected. |
| `uninitialized-local`, `CrownHook._crown` beneficiary / paid / asClaim | Solidity initializes these value types to zero/false. Failed registry reads return without charging; direct transfers and claim fallback explicitly set success flags. The relevant fail-open and accounting paths are covered by existing tests. No hook change was needed. |
| `uninitialized-local`, v4 `Hooks.afterSwap` hookDelta | Intentional zero delta when no callback returns one. Protected dependency. |
| `unused-return`, six v4 `Hooks` initialization/liquidity/donate callbacks | Their return bytes are checked by `callHook`; these callers need only successful callback validation, not a decoded custom delta. Protected dependency. |
| `unused-return`, `CrownHook.redeemClaim` PoolManager.unlock | Redemption is a side effect. The unlock callback settles and returns empty bytes; no return payload is needed by the external method. Existing authorization and redemption tests pass. |

## Frontend review boundaries

All visitor transactions target loaded, code-checked contracts and use implementation-derived ABIs. Amounts use bigint and reject precision below one wei. Receipt-uncertain actions stay locked. Wrong-chain and failed-read states cannot execute. The review dialog repeats the bond/slash, beneficiary and authorization consequences. Public configuration contains no private credentials.

No workflow deployment or vetted Uniswap network file was supplied, so production contract addresses remain absent. There is no claim that the published deployment, real-wallet onboarding, passkeys, mobile app handoff, Sourcify submission or live Robinhood transactions were verified. The acceptance and design review evidence is in `VALIDATION.md`.
