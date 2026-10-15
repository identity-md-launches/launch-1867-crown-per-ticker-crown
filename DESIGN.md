# Crown interface design

## Overview

Crown is a working ticker registry for people choosing between a reigning token and a challenger. The first view puts the selected ticker, chain, wallet, current crown and the appropriate challenge action together. It retains the original site's dark background and gold crown identity, replacing the earlier stacked prototype with a responsive application.

The composition is quiet and compact: shared edges, flat sections, a gold primary action, small numeric summaries and plain language about the stake and slash. Live values are distinguished from unavailable data. There are no invented statistics, decorative charts, marketing hero or automatic page-load animation.

## Colors

The single dark palette is in `site/src/styles.css:1`. There is no theme switch or unused light palette.

| Token | Value | Role |
| --- | --- | --- |
| `--bg` | `#121612` | Page and input background |
| `--surface` | `#1b211a` | King panel, dialogs, disabled surfaces |
| `--surface-raised` | `#232b21` | Hover and selected controls |
| `--text` | `#f4f5ed` | Primary text |
| `--muted` | `#b5bdb1` | Secondary labels and instructions |
| `--border` | `#414a3d` | Dividers and control boundaries |
| `--accent` | `#e5bb68` | Crown, ticker emphasis and primary transaction action |
| `--accent-hover` | `#f3cd85` | Primary-action hover |
| `--ink` | `#1b2016` | Text on gold controls |
| `--success` | `#c0d7a9` | Connected-wallet indicator |
| `--danger` | `#ffb0a6` | Persistent, textual errors |
| `--focus` | `#f3cd85` | Two-pixel keyboard outline with four-pixel offset |

The crown seal uses `#28291c` and `#806b43`. The king's stake-bar segment uses `#93b37a`; the challenger uses gold. The numeric labels make the bar meaningful without color perception. Disabled primary controls use `#525b48` with `#f0f1e9` text. The final probe measured the rendered text pairs against solid backgrounds; its results and coverage limits are in `VALIDATION.md`.

## Typography

`styles.css` declares Inter followed by local UI/system sans-serif fallbacks; no Inter font file is loaded or fetched, so the available system fallback renders the interface. Georgia / Times New Roman / serif is reserved for the explanatory section's heading. There are no remote fonts. Do not assume a computed CSS family list proves a particular font is installed.

Six named sizes form the scale: `--text-sm` 14px, `--text-body` 16px, `--text-heading` 20px, `--text-subtitle` 24px, `--text-title` 32px and `--text-display` 48px at the 16px root. The phone view uses five sizes because its page title is 32px. The three weights are 400, 600 and 700; the page title uses 700, the heaviest weight.

Body line height is 1.5. The page title uses 1.1 and −0.04em tracking, section headings 1.3 and compact headings 1.4. Forms use 16px inputs to avoid automatic mobile zoom. All numeric values use tabular figures. Text can wrap naturally; headings balance, prose uses pretty wrapping, and addresses/hash values use `overflow-wrap: anywhere`. Monetary data is never forced into a smaller type size to fit.

## Layout

`App.tsx` is the single page; `#ticker=…` preserves the selection without a server rewrite. `styles.css` defines a 1184px content width and a 1248px header width including its 32px padding. Shared spacing uses 8, 12, 16, 20, 24, 32, 40, 48 and 64px for controls, groups and section separation.

The desktop crown grid has columns in a 1.14:1 ratio with a 24px gap. The king uses a filled surface; its adjacent action uses a structural border. Totals form four columns. Refund and fee-claim sections use two columns with a 64px gap. The explanation uses an introduction and a numbered list in two columns.

At 1250px, main/footer acquire 32px side margins. At 900px, padding and gaps compress. At 700px, the page becomes one column with 16px margins, navigation links leave the header, and the ticker search becomes a horizontal label/control row. Totals retain two columns. The wallet control stays in the header.

On mobile, an active challenge moves the action panel before the king panel so the stakes, countdown and vote action remain on the first screen. With no live challenge, the compact crown panel uses 16px padding and precedes the bond/address action, leaving room for its connected-wallet address controls. Detailed timestamps and the ticker hash use a native disclosure. Normal document flow is used throughout; there is no sticky content covering controls.

Browser checks cover 320, 390, 768 and 1440px for connected maximum-size amounts, plus the design probe's 320, 390 and 1440px default states. The 390px challenge and active-vote actions were measured within the first 844px and their screenshots inspected. Other widths interpolate responsively; physical-device and browser-native zoom limits are recorded in validation.

## Elevation & Depth

The surface system is flat, with no card shadows or gradient text. Tone separates the king panel from the page. Borders communicate control boundaries, state and section division. Native dialogs sit in the browser's top layer over a 75%-black backdrop; the rest of the document is inert while a modal is open.

## Shapes

Inputs/buttons have 8px radii. Main panels have 12px radii. Dialogs have 16px radii; on phones the wallet dialog becomes a bottom sheet with rounded upper corners. The crown seal is circular. The stake bar is 6px tall with a 4px radius; clipping there affects decoration only. No critical text is clipped.

## Components

| Component / source | Reuse and behavior |
| --- | --- |
| `Wallet`, `site/src/Wallet.tsx` | One header control for connection, account menu and chain switching. Named extension rows, bundled wallet marks, phone links and Coinbase. Native dialog, Escape/backdrop/close button, keyboard focus return. Per-row connection pending state. |
| `Transaction`, `site/src/Transaction.tsx` | Shared prepare → simulate → review → sign → confirm flow. Gold `primary` or outline secondary button. The caller supplies its exact action, description and eligibility. Persistent errors and receipt links; unknown confirmation remains locked with a receipt-retry control. Field errors can focus and describe their input. |
| `AddressView`, `site/src/App.tsx` | Checksummed shortened address, full-address accessible label/title, explorer and copy control. Clipboard failure reveals the full selectable value. |
| `Fact`, `site/src/App.tsx` | Definition-list label/value row. Text and addresses wrap; timestamps include UTC. |
| Crown/state sections, `site/src/App.tsx` | Distinct awaiting-deployment, unregistered, minimum-reign, active, timelocked and finalizable states. Unavailable data says “Not loaded,” without zeros that could be mistaken for chain observations. |
| `OwnerPanel`, `site/src/OwnerPanel.tsx` | Progressive disclosure shown only to the hook's on-chain owner. Configures future pools; never presented as a live-pool fee setter. |
| `useCrown`, `site/src/useCrown.ts` | Data dependency for these components: verified binding, consistent-block snapshots, five-second visible-tab polling and wallet-specific balances. Errors pause actions. |

Controls are at least 44px tall except secondary copy/refresh controls, which are at least 32px and remain spaced. Labels are visible; placeholders only show examples. Focus uses `:focus-visible`. Validation and transaction errors announce through alert/status regions. The primary action never gains fake functionality when data or eligibility is missing.

Interaction transitions name background color, border color and scale, last 120ms, and use the guide's 0.96 press scale. A small progress spinner accompanies pending text. Reduced-motion preference removes both animation and transitions and disables the press scale. Forced-colors mode preserves a system-colored focus outline and button boundary.

Assets: `site/public/favicon.svg` and the `Crown` component are code-native crown marks. `site/design/social.svg` generates `site/public/social.png` at 1200×630 for social sharing. Wallet SVGs and their attribution are local. The social image URL remains relative until hosting supplies a canonical origin.

## Do's and Don'ts

- Reuse the semantic color and type tokens, `Fact`/`AddressView` rows and `Transaction` for another contract action.
- Put the current state and its next meaningful control before explanatory prose; use an outlined secondary control when the primary action is already present.
- Keep inputs, contract units, recipient and downside next to the decision. Describe an authorization before presenting its confirmation.
- Preserve real missing/error states. Do not turn unknown balances into zero or use deployment fixtures as addresses.
- Keep text selectable and full addresses reachable; do not hide overflow to disguise layout defects.
- Add a new section in the existing flow with a heading, compact description and the appropriate shared controls. Do not add a new card layer, type scale, font dependency or remote asset for one section.
