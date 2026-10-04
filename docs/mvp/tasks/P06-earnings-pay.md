# P06 · Earnings, pay rules, payouts

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P04, L09, C07 | M | 14 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-05 §8.10–§8.11; SPEC-01 §4.9; SPEC-03 §3, §5.8; SPEC-02 §3.4 (silence), §3.6 (departure); SPEC-07 earnings rows; SPEC-09 §4.
**Paths:** `lib/openmaru/funding/pay/**`, controllers, migrations, Oban workers, `web/src/features/{org,settings}/earnings/**`

## Goal
An org's people are paid from what supporters pay above cost, by rules anyone can read, and every payment is on the record. openmaru moves no money: it computes what each person is owed, and the org records each payment with proof.

## Deliverables
- Migration `payouts`.
- **Pay run** (SPEC-05 §8.10). Monthly on the 1st at 04:00 UTC, after pledge charges; idempotent per org and month.
  - E = earnings credited in the previous month.
  - The pay rules of the version active at the run apply.
  - Each eligible payee (an active member, neither silent nor suspended) is owed `min(max, floor(E × share / 100))`: code 40 to `payable`, a `payouts` row, and `pay.owed`.
- **Recording a payment.** `POST /orgs/:slug/payouts/:id/paid {proof_upload_id}`:
  - administrators only;
  - the upload has purpose `proof`;
  - code 41, `status: paid`, `recorded_by_user_id`, `pay.paid`.
- **Retaining earnings.** `POST /orgs/:slug/earnings/retain {amount_micros}`, administrators only: code 42 to the treasury, top-ups, `earnings.retained`.
- **`GET /orgs/:slug/earnings`:** pay rules, earnings, owed and paid by month, and amounts owed for more than 60 days. It also marks which reviewers in P04's funding view are payees.
- **Web.**
  - The earnings part of the org page's "How money works": pay rules, earnings, owed and paid by month, overdue amounts, who recorded each payment.
  - Settings: owed payouts with "record as paid" (proof upload), and retaining earnings.

## Tests to write first
- [ ] **P06-T01** Pay run:
  - Setup: September earnings of $1,000, with pay rules `@mina 40% <= usd 300 / month` and `@jo 25% <= usd 4_000 / month`.
  - Owed: mina $300, jo $250 (code 40, `pay.owed`); $450 stays in earnings.
  - Rerunning creates nothing new.
- [ ] **P06-T02** Eligibility:
  - A silent, departed or suspended payee is owed nothing for that month.
  - What they were owed before stays owed, and returning makes them eligible from the next run.
- [ ] **P06-T03** An org without a margin has no earnings: the run owes nothing.
- [ ] **P06-T04** The run uses the pay rules active at the run: a version activated on September 20 with new shares applies to the October 1 run.
- [ ] **P06-T05** Recording a payment:
  - An administrator with a stored `proof` upload → code 41, `paid`, `recorded_by_user_id`.
  - A payee who is an administrator may record their own payment, and the record shows it.
  - A non-administrator → 403. No proof, or a proof from another org → 422. Replay → `:exists`.
- [ ] **P06-T06** Retaining:
  - An administrator moves $100 of unclaimed earnings → treasury credited (code 42), and shortfalls are topped up.
  - More than the earnings balance → 422.
- [ ] **P06-T07** `GET /orgs/:slug/earnings` shape: amounts as strings with display forms. An amount owed for 61 days is flagged. Proof links appear only for members (SPEC-09 §4).
- [ ] **P06-T08** Web:
  - The earnings section renders pay rules and monthly amounts.
  - "Record as paid" uploads a proof and calls the API, and retaining calls the API; both are hidden for non-administrators.
  - Axe reports no violations.

## Out of scope
Moving money to people (off-platform by design). Tax forms and payee identity checks. Pay periods other than a month.
