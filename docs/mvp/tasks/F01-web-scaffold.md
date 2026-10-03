# F01 · Web scaffold, design system, auth

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | C01, C02, L04 | M | 5 |

**Read first:** SPEC-08 §1, §2, §4; SPEC-07 auth rows, §2; SPEC-09 §1 (CSRF), §8 (CSP constraints); the prototype `Openmaru_Landing.html` (tokens, sign-in card, keyboard behavior).
**Paths:** `web/**`

## Goal
The React app shell every screen builds on: tokens and themes from the prototype, typed API client, auth screens, realtime plumbing, shared formatters that match the charter exactly.

## Deliverables
- Vite + React 19 + TS strict; React Router; TanStack Query; Zustand; ESLint + Prettier; Vitest + Testing Library + MSW + `vitest-axe`.
- `src/styles/tokens.css` (SPEC-08 §2 incl. three themes and dark mode), self-hosted fonts.
- `src/lib/api`: fetch wrapper with CSRF header, `ApiError {code, status, details}`, generated types from `/api/v1/openapi.json` (`pnpm gen:api`).
- `src/lib/format`: money/duration/date/list/threshold formatters driven by `crates/maru_core/tests/vectors/human.json`.
- `src/lib/realtime`: Phoenix socket wrapper + per-topic reducers into the query cache.
- Components: `Button`, `Input`, `Card`, `Pill`, `Dialog`, `Toast`, `ProvenanceBadge`, `Money`, `Kbd`, `ShortcutsProvider`, `MarkdownInline` (charter strings as CommonMark inline content, raw HTML off, no GFM extensions or typographer; SPEC-08 §4, OQ-12).
- Screens: sign-in card (passkey, GitHub, Google; no email field in the MVP, OQ-8), handle picker, `/device` approval.
- Right after the handle picker, offer to add a second passkey or link GitHub/Google (skippable). C01 has no account recovery, so a user with a single passkey who loses the device loses the account.

## Tests to write first
- [ ] **F01-T01** Shell renders with graphite tokens; theme switch applies `data-theme` and persists across reloads.
- [ ] **F01-T02** Money formatter passes every money vector in `human.json`.
- [ ] **F01-T03** Duration, date, list, threshold formatters pass their vectors.
- [ ] **F01-T04** API client: error envelope → `ApiError` with code; 401 triggers the auth redirect; mutations send `x-csrf-token`.
- [ ] **F01-T05** Passkey sign-in: options → `navigator.credentials.get` (mocked) → login → navigates to returnTo.
- [ ] **F01-T06** Passkey sign-up and GitHub/Google buttons point at the OAuth routes.
- [ ] **F01-T07** Handle picker: client-side regex feedback; server `handle_taken` shown inline.
- [ ] **F01-T08** Device page: entering `ABCD-EFGH` and approving shows success; unknown code shows an error.
- [ ] **F01-T09** Shortcuts: `/` focuses search, `?` opens help, `Esc` closes the top overlay; ignored while typing in inputs.
- [ ] **F01-T10** `useReducedMotion` true → animated components render static.
- [ ] **F01-T11** `ProvenanceBadge` renders ●/◐/○ with label and tooltip; accessible name includes the tier.
- [ ] **F01-T12** Realtime reducer: a `ledger` event prepends into the goal-ledger query cache without refetch; unknown events ignored.
- [ ] **F01-T13** Axe: no violations on the shell and sign-in card, both themes, light and dark.
- [ ] **F01-T14** After a first handle is picked, the user is offered "add another passkey" (registration options with the session) and "link GitHub/Google"; skipping goes to returnTo.
- [ ] **F01-T15** `MarkdownInline` renders `**core**` as bold and L04's escapes literally (`\*x\*`, `\[a](b)`, `\# Rules` show as typed). Raw `<b>x</b>`, `<script>`, `https://evil.example`, `www.evil.example` and `~~x~~` render as plain text with no element other than `strong`/`em`/`code`, and `"a" -- (c)` is unchanged.

## Out of scope
Feature screens (F02–F08).
