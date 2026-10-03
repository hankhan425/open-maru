# F07 · Giving flow & payments settings

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F06, P02, P03, P04 | M | 14 |

**Read first:** SPEC-05 §1–§4, §6, §8.1–§8.5, §8.9, §8.11; SPEC-03 §5.6 (own funds); SPEC-08 §3 (Org, Giving, Settings).
**Paths:** `web/src/features/donate/**`, `web/src/features/org/money/**`, `web/src/features/settings/payments/**`

## Goal
Giving takes under a minute and ends with a clear receipt of where the money goes. Before paying, supporters see who receives the money, what the margin is, and what protects them. Afterwards they can follow their money to the work it paid for. Administrators record own funds, connect Stripe and see reconciliation.

## Deliverables
- **Giving dialog** on a goal (`GET /orgs/:slug/funding`):
  - It shows the recipient (display name, country, connector) and the margin, as "for every $1 of work, you pay $1.15; $0.15 pays the org's people". It explains the protections in one line each, and says why when the goal takes nothing.
  - Pledge: a monthly cap, explained as "you pay for accepted work after it's done, up to this"; then the setup redirect.
  - Donation: presets, custom amount, monthly toggle; then the Checkout redirect.
  - Both: public-name opt-in.
- **Thanks/receipt page:** cost, margin and fee lines, and the money trace of the lot (the spend it paid for, with tasks and evidence, and the margin earned).
- **Pledge page** (`/pledges/:id?t=`): charges with the tasks they paid for, their margin part and the part donations already paid; cancel; reconfirm, which shows the current margin.
- **"How money works" on the org page**, all except earnings and pay (P06): recipient, margin, review, track record, rule flags, refunds and dormancy records.
- **Payments settings tab:** Stripe onboarding and status, reconciliation, own-funds contributions (administrators).
- `parseUsdToMicros(string)` using string arithmetic.

## Tests to write first
- [ ] **F07-T01** Presets $10/$25/$50/$100; custom amount validation (≥ 1, ≤ 10,000, ≤ 2 decimals); public name field appears only when opted in.
- [ ] **F07-T02** Submit posts checkout and assigns `window.location` to `checkout_url` (mocked).
- [ ] **F07-T03** `payments_not_enabled` and `goal_closed` show friendly messages.
- [ ] **F07-T04** The thanks page with a token shows the amount, its cost and margin lines, fee lines, the goal link and the money trace. A bad token → not found.
- [ ] **F07-T05** Settings (administrators): onboarding button redirects to the link; status shows charges/payouts and requirements; hidden for non-administrators.
- [ ] **F07-T06** Reconciliation list shows ok/mismatch/error runs with details.
- [ ] **F07-T07** `parseUsdToMicros`: `"12.34"`→`"12340000"`, `"0.01"`→`"10000"`, `"1,000"` rejected, `"1e3"` rejected; never uses floats.
- [ ] **F07-T08** Giving availability:
  - A goal taking money offers both pledge and donation.
  - `not_accepting_money` shows its reason (`no_recent_work`, `dormant`, `connector_unavailable`), and `outside_money_cap_reached` says how much the goal can take now.
  - The recipient and margin lines appear before any redirect. Without a margin, the dialog says supporters pay cost only.
- [ ] **F07-T09** Pledge flow:
  - Cap validation ($1–$10,000); setup redirect (mocked).
  - A pledge page listing charges with their tasks, margin parts and donation-paid parts; cancel and reconfirm call the API.
- [ ] **F07-T10** Settings: an administrator records an own-funds contribution to the treasury or a goal; hidden for non-administrators.
- [ ] **F07-T11** "How money works" on the org page renders each disclosure from a fixture, with the lumen rule flags (P04-T14), and every money figure links to the ledger. Axe reports no violations.
