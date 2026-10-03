# F07 · Giving flow & payments settings

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F06, P02, P03, P04 | M | 14 |

**Read first:** SPEC-05 §1–§4, §6, §8.1–§8.4; SPEC-03 §5.6 (own funds); SPEC-08 §3 (Giving, Settings).
**Paths:** `web/src/features/donate/**`, `web/src/features/settings/payments/**`

## Goal
Giving takes under a minute and ends with a clear receipt of where the money goes. Donors can always see what their money pays for and what protects it. Administrators record own funds, connect Stripe and see reconciliation.

## Deliverables
- Giving dialog on a goal, as its funding tier allows (`GET /orgs/:slug/funding`). It explains the protections in one line each, and states when the goal takes nothing.
  - Pledge (tier 1+): a monthly cap, explained as "you pay for accepted work, up to this"; then the setup redirect.
  - Donation (tier 2): presets, custom amount, monthly toggle; then the Checkout redirect.
  - Both: public-name opt-in.
- Thanks/receipt page; pledge page (`/pledges/:id?t=`) with charges and the tasks they paid for, plus cancel and reconfirm.
- Payments settings tab: Stripe onboarding and status, reconciliation, own-funds contributions (administrators).
- `parseUsdToMicros(string)` using string arithmetic.

## Tests to write first
- [ ] **F07-T01** Presets $10/$25/$50/$100; custom amount validation (≥ 1, ≤ 10,000, ≤ 2 decimals); public name field appears only when opted in.
- [ ] **F07-T02** Submit posts checkout and assigns `window.location` to `checkout_url` (mocked).
- [ ] **F07-T03** `payments_not_enabled` and `goal_closed` show friendly messages.
- [ ] **F07-T04** Thanks page with token shows amount, fee lines, net to goal, goal link; bad token → not found.
- [ ] **F07-T05** Settings (administrators): onboarding button redirects to the link; status shows charges/payouts and requirements; hidden for non-administrators.
- [ ] **F07-T06** Reconciliation list shows ok/mismatch/error runs with details.
- [ ] **F07-T07** `parseUsdToMicros`: `"12.34"`→`"12340000"`, `"0.01"`→`"10000"`, `"1,000"` rejected, `"1e3"` rejected; never uses floats.
- [ ] **F07-T08** Giving by tier: tier 0 shows that the goal is funded by its org only; tier 1 offers a pledge only; tier 2 offers both. `funding_tier_required` and `outside_money_cap_reached` show friendly messages.
- [ ] **F07-T09** Pledge flow: cap validation ($1–$10,000), setup redirect (mocked), and a pledge page listing charges with their tasks; cancel and reconfirm call the API.
- [ ] **F07-T10** Settings: an administrator records an own-funds contribution to the treasury or a goal; hidden for non-administrators.
