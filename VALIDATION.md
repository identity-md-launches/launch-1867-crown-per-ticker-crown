# Crown frontend validation

Validated 2026-10-15. This is worker-side evidence for the bounded frontend assignment, not an independent audit or a live deployment attestation.

## Scope and result

**Complete for the frontend delivery scope, with deployment-dependent behavior explicitly unverified.** The Vite/React/TypeScript source, package manifest, lockfile, implementation-derived ABIs and production `dist/` are present. The static export contains 18 files totaling **833,082 bytes**. Required metadata includes the page title, description, favicon, Open Graph title and a local 1200×630 PNG.

The starting tree contained the accepted contracts and a basic static site. No deployment handoff or vetted network file was supplied. The final production configuration has an empty contract set, labels the page “Awaiting deployment,” and does not enable a transaction against guessed addresses. Public RPC chain ID 4663 was verified; contract code, real balances, signatures and transactions on Robinhood Chain were not. Deployment remains the network's after-review step.

The one scoped Solidity change addresses a high-only Slither failure in the inherited treasury fallback. Its authorization, accounting and regression coverage are explained in `REVIEW.md`. Existing build configuration, dependencies and contract economics were preserved.

## Executed checks

| Check | Result |
| --- | --- |
| `npm --prefix site run typecheck` | Pass, TypeScript 7.0.2 |
| `npm --prefix site run build` | Pass, Vite 8.3.4; relative base; complete static export |
| Clean `npm ci --offline --no-audit --no-fund` from the submitted lockfile, then typecheck and production build | Pass in a separate task-owned scratch copy; generated files compared byte for byte |
| `PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright npm --prefix site test` | **49 production-page interaction assertions passed**, plus handoff/export integrity tests |
| Pinned `taste.mjs --out test/scratch/taste` with the supplied Playwright/Chromium runtime | **16/16 checks passed** |
| `forge build --offline` | Pass; actual Solidity compiled |
| `forge test --offline --fuzz-seed 0xa908c30cb219622afabe396eaeadd8c0292e9f40418d5df9144d10a50cde150d` | **67 passed, 0 failed, 0 skipped**, including registry/hook invariant suites and buy → challenge → stake → finalize → buy |
| Fresh source export: build, exact-seed tests, `forge fmt --check`, high-only Slither | Pass; all 67 tests passed, high-only scan **0 results** |
| `forge test --offline --fuzz-seed 0x20261015 --fuzz-runs 1024` | 67 passed; existing inline run counts remain authoritative where present (256/512 in those tests) |
| `forge build --offline --sizes` and `forge fmt --check` | Pass |
| Medium-inclusive Slither | 12 retained results, nonzero exit; dispositions in `REVIEW.md` |
| ABI consistency | All five arrays in `site/public/abi/` and `dist/abi/` match final compiler artifacts |
| Submission contents | Under 4.5 MiB uncompressed, below the 8 MiB cap; no dependency directories, package caches, archive vendors or gitlinks included; protected paths unchanged |

The isolated source export included tracked source plus allowed new files, and excluded pinned workflow inputs, outputs/caches, dependency directories and `test/scratch/`. It required neither the frontend dependency installation nor network access to compile and run Foundry. It was an exported submission candidate, not a claim of a separate Git commit. The worker owns final submission/commit handling.

High-only Slither command:

```sh
slither . --exclude-informational --exclude-optimization --exclude-low --exclude-medium
```

Medium-inclusive command after that compile:

```sh
slither . --ignore-compile --exclude-informational --exclude-optimization --exclude-low
```

Launchable contract sizes:

| Contract | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| CrownHook | 7,255 | 13,437 |
| CrownRegistry | 5,690 | 5,716 |
| CrownToken | 1,552 | 2,504 |
| CrownChallengerToken | 1,552 | 2,557 |

All are below the 24,576-byte runtime and 49,152-byte initcode limits. The compiler settings remain Solidity 0.8.26, Cancun, optimizer enabled / 200 runs, via-IR, `bytecode_hash = "none"`, and CBOR metadata enabled, as pinned by the existing `foundry.toml`.

## Interaction evidence

`site/tests/interaction.mjs` serves the **production export under `/preview/`**, injects an EIP-6963 provider and mocks RPC calls at the configured public endpoint. Fixture addresses never enter `dist/`. These tests exercise real UI event handlers and ABI-encoded wallet requests, not substitute button implementations.

- Disconnected and unconfigured state: honest missing deployment, disabled writes, working wallet control, a useful missing-wallet error, Escape and restored trigger focus.
- Wrong chain: actions disabled; a 4902 switch failure causes add-chain and a second switch. Prepared reviews cancel on a network change.
- Live state: current king and beneficiary, both stakes, quorum, countdown, boundary between staking and timelock, and boundary allowing finalization.
- Challenge: invalid and same-token addresses rejected, custom ABI errors translated, exact 0.01 ETH and ticker hash asserted, beneficiary described before signing.
- Stake: selected side and exact wei value asserted, precision below one wei rejected, pending lock checked after the transaction hash.
- Receipt recovery: a provider failure leaves the action locked; **Check confirmation** retrieves the original receipt without another submission.
- Finalize: the post-confirmation king token and beneficiary change; a finished challenge remains discoverable for its refund.
- Refund: claimability checked, zero transaction value, invalid challenge number cannot claim.
- Fee claims: separate confirmed PoolManager authorization, exact ETH redemption, and permission revocation.
- Additional primary controls: permissionless treasury retry, owner-only future-pool configuration with fee/bps/key assertions, first registration for an uncrowned ticker.
- RPC failure: stale cached data does not permit writes; a successful refresh restores readiness.
- Phone wallets: all four app-browser links and Coinbase Smart Wallet row render, with Rabby's documented command/query checked.
- Keyboard: Tab reaches the primary action, Enter opens its review, Tab reaches confirmation, modal isolation refuses focus on background inputs, and Enter activates confirmation. Focus outline screenshot inspected.
- Layout stress: maximum uint256 totals at 320, 390, 768 and 1440px, with full addresses exposed in forms/details. No horizontal overflow. The disconnected, connected challenge and active-stake primary buttons were measured wholly inside the first 844px at 390px width.

`site/tests/export.mjs` separately validates a synthetic workflow handoff in `test/scratch/`: exact identifiers and contract set, unchanged pool key/network/wallet-add-chain values, canonical Keccak ABI binding, SHA-256 for every exported file except the manifest itself, runtime manifest selection, and rejection of a changed ABI. This tests the implemented handoff path; it is not evidence that an actual deployment handoff existed.

## Better Interface review

All six pinned core domains were read and applied. Evidence comes from source review, the pinned probe, browser interactions and inspected screenshots.

| Domain | Coverage | Evidence / limits |
| --- | --- | --- |
| Accessibility | Checked | Native controls, visible labels, modal dialogs, focus outline, keyboard activation/isolation/return, linked candidate-field error, live error/status feedback, reduced motion and forced-colors CSS. No real screen-reader or physical-device session. |
| Layout | Checked | Product/action on first 390px screen, normal-flow controls, adaptable grid, maximum-amount reflow, no measured overlap/clipping/sideways scroll at probe widths. Browser-native 200% zoom and RTL/localization were not performed. |
| Writing | Checked | Verb-first actions, exact bond and risk, beneficiary consequence, no fake chain data, receipt uncertainty explained, missing-wallet and RPC recovery instructions. |
| Typography | Checked | Five sizes at 390px, six at 1440px, three weights and two declared family stacks; 16px inputs; tabular numbers; wrapping hashes. No remote font load or claim that Inter is installed. |
| Colors | Checked | All probe-measured default-state text meets WCAG thresholds; minimum measured ratio **6.26:1**, the disabled opening-action text. Color is accompanied by status text and numeric stake labels. This does not claim exhaustive contrast measurement of every wallet-vendor UI. |
| UI | Checked | Hover/pressed/focus/disabled/pending/empty/error states, native disclosures, deliberate flat surfaces, local crown and wallet marks, bounded transitions. Reduced-motion probe passed. No motion timeline slow-play session was performed. |

Final taste checks: render, layout, targets, contrast, casing, tracking, eyebrows, type sizes, type faces, glyphs, slogans, repetition, copy budget, chrome, motion and share all pass. Two secondary controls are below the comfortable 44px size but above the probe's accessible-size/spacing threshold. The contrast and render claims refer to this production export, not source-only assumptions.

## Findings corrected during implementation

| Finding | Source / reproduction | Fix and recheck |
| --- | --- | --- |
| High: wrong-chain wallet client cached an error | `site/src/Transaction.tsx:14`; connect on chain 1, switch, then try to confirm a reviewed call | Fetch wallet client only on the configured chain and gate actions on its readiness. Exact switch/signing flow passes. |
| High: finalization preparation reset its own UI | `site/src/App.tsx:117`; opening the finalize review changed the selected-challenge query and unmounted the control | Preserve selection only after confirmation. Finalize and subsequent refund pass. |
| High: receipt uncertainty could permit a duplicate | `site/src/Transaction.tsx:67`; receipt provider fails after the wallet returns a hash | Preserve the pending lock and allow receipt recovery. No second send occurs in the failure/retry test. |
| Medium: placeholder mobile URL was incompatible with Rabby's parser | `site/src/Wallet.tsx:10`; inspect the vendor's open-dapp parser | Use `_cmd=open-dapp&dapp=…` on `/mobile/`; query parameters are asserted in the mobile test. Native app launch remains untested. |
| Medium: preflight field errors lacked field association | `site/src/Transaction.tsx:33`; submit an invalid candidate | Focus the input and link `aria-invalid` / `aria-describedby` to its error; verified in-browser. |
| Layout: wallet button was detected above the page title | `site/src/styles.css:161`; first 390px probe reported one eyebrow | Increase the header/title separation. Final probe has no eyebrow findings. |
| Layout: connected address controls used more vertical room | `site/src/styles.css:169`; inspect the connected 390px screen | Compact the mobile king panel without shrinking its text or controls. Connected primary button now fully fits without scrolling. |
| High static-analysis gate: treasury fallback state write after ETH call | `src/CrownRegistry.sol:301`; initial high-only Slither run | Revert-isolated, self-only payout; regression, invariants, exact-seed tests and clean-export high-only Slither pass. See `REVIEW.md`. |

Reproducible scratch evidence: `test/scratch/taste/shots/390.png`, `390-full.png`, `1440.png`, `1440-full.png`; `test/scratch/interaction/390-pending.png`, `390-active.png`, `390-keyboard-focus.png`, `390-wallet.png`, and `1440-connected.png`. These are temporary verification outputs, not required production assets. They are removed before submission, and tests can regenerate them.

## Limitations and after-launch verification

- No real workflow deployment/network files were supplied; no deployed addresses or live full-cycle demo were invented.
- No real signature, funded transaction, passkey onboarding, physical mobile-wallet handoff, IPFS publication or Sourcify verification was attempted. The public chain-ID read is the only live-chain observation claimed.
- Swaps/liquidity are outside this ticker-page assignment and remain unavailable; no unvetted Uniswap addresses were inserted.
- Current ticker totals/claims are for native ETH, matching this launch. Historical challenge refunds require a challenge number. No indexer, USD feed or ENS deployment was supplied.
- A receipt lock is held in page memory. After reloading a page with an uncertain transaction, inspect the wallet/explorer before repeating it.
- Vite emits an advisory about the main JavaScript chunk exceeding 500kB uncompressed. Total exported bytes remain below 1 MiB, with Coinbase in a lazy chunk and no runtime CDN dependencies for application assets.
- The remaining 12 medium Slither results are disclosed and justified in `REVIEW.md`; no clean-medium claim is made.
- Open Graph paths are relative because the final hosting origin is not yet supplied. The share PNG is present and visually inspected; unfurling on the final host remains an after-publication check.
