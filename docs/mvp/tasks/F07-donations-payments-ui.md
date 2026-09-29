# F07 · Donation flow & payments settings

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F06, P02, P03 | M | 14 |

**Read first:** SPEC-05 §1–§4, §6; SPEC-08 §3 (Donation, Settings).
**Paths:** `web/src/features/donate/**`, `web/src/features/settings/payments/**`

## Goal
Giving takes under a minute and ends with a clear receipt of where the money goes; administrators can connect Stripe and see reconciliation.

## Deliverables
- Donate dialog (presets, custom amount, monthly toggle, public-name opt-in, destination goal/treasury) → Checkout redirect; thanks/receipt page; payments settings tab.
- `parseUsdToMicros(string)` using string arithmetic.

## Tests to write first
- [ ] **F07-T01** Presets $10/$25/$50/$100; custom amount validation (≥ 1, ≤ 10,000, ≤ 2 decimals); public name field appears only when opted in.
- [ ] **F07-T02** Submit posts checkout and assigns `window.location` to `checkout_url` (mocked).
- [ ] **F07-T03** `payments_not_enabled` and `goal_closed` show friendly messages.
- [ ] **F07-T04** Thanks page with token shows amount, fee lines, net to goal, goal link; bad token → not found.
- [ ] **F07-T05** Settings (administrators): onboarding button redirects to the link; status shows charges/payouts and requirements; hidden for non-administrators.
- [ ] **F07-T06** Reconciliation list shows ok/mismatch/error runs with details.
- [ ] **F07-T07** `parseUsdToMicros`: `"12.34"`→`"12340000"`, `"0.01"`→`"10000"`, `"1,000"` rejected, `"1e3"` rejected; never uses floats.
