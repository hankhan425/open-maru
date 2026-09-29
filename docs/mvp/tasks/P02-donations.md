# P02 · Donations, fees, refunds

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P01, G02 | L | 9 |

**Read first:** SPEC-05 §4–§5 (all); SPEC-03 §5.3 (top-ups), §5.5; SPEC-02 §7 (donor privacy).
**Paths:** `lib/openmaru/payments/donations/**`, controllers, migrations

## Goal
Donors give once or monthly to a goal or treasury via Stripe Checkout on the org's own account; every cent (gross, fees, refunds) is mirrored in the ledger exactly once.

## Deliverables
- Migration `donations`.
- `Openmaru.Payments.Donations`: `checkout/1`, webhook handlers for every event in SPEC-05 §4.2 except `account.updated`, `receipt/2`.
- Ledger chains with deterministic ids; fee `spend_records` (source `stripe`, tier `verified`); treasury credits trigger `Funding.top_up/1`.
- Endpoints `POST /donations/checkout` (rate-limited), `GET /donations/:id/receipt?t=`.
- Administrator alerts (inbox item + `members` activity) for disputes and `refund_unfunded`.

## Tests to write first
- [ ] **P02-T01** Validation: < $1, > $10,000, fractional cents → 422; `charges_enabled` false → 409 `payments_not_enabled`; closed goal → 409 `goal_closed`.
- [ ] **P02-T02** One-time session params: `Stripe-Account` set, `mode=payment`, `payment_method_types=["card"]`, cents amount, product name, application fee `floor(cents × bps / 10_000)` (omitted when 0), metadata, success/cancel URLs, 30-min expiry; donation `pending`; only receipt-token hash stored.
- [ ] **P02-T03** Monthly session: `mode=subscription`, monthly recurring price, `application_fee_percent`, subscription metadata.
- [ ] **P02-T04** `checkout.session.completed` → PaymentIntent retrieved with `latest_charge.balance_transaction`; fees from `fee_details`; donation `succeeded`; 3 linked transfers with deterministic ids; 2 fee spend records; `donation.received`.
- [ ] **P02-T05** Replayed webhook → no new transfers (`:exists`).
- [ ] **P02-T06** Treasury donation → treasury credited, top-up invoked.
- [ ] **P02-T07** `invoice.paid`: first invoice completes the original donation; the next creates a child with `parent_donation_id`.
- [ ] **P02-T08** Partial then full refund → per-refund transfers; status `partially_refunded` then `refunded`; `refunded_micros` correct.
- [ ] **P02-T09** Refund when goal funds are spent → falls back to treasury; both insufficient → `refund_unfunded` + alert, no transfer.
- [ ] **P02-T10** Dispute created → `disputed` + alert; closed lost → refund-like transfer; closed won → back to `succeeded`.
- [ ] **P02-T11** `checkout.session.expired` → `expired`; `customer.subscription.deleted` → series ended.
- [ ] **P02-T12** Receipt with the right token → amount, fees, net, goal link, goal spend since donation; wrong token → 404.
- [ ] **P02-T13** Activity payloads: anonymous by default; display name only with `donor_public`; no email anywhere in DB columns or payloads.
- [ ] **P02-T14** 11th checkout within a minute from one IP → 429.

## Out of scope
Reconciliation (P03), donation UI (F07).
