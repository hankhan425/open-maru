# SPEC-05 — Payments (Stripe Connect)

## 1. Model (ADR-2, non-custodial)

- Each org connects its **own** Stripe account as a Connect account with full Stripe Dashboard access (the classic `type=standard`; with controller properties: Stripe collects requirements, the connected account pays fees and bears losses).
- Donations are **direct charges** created on the connected account (`Stripe-Account` header). The org is merchant of record. openmaru takes an optional **application fee** (`PLATFORM_FEE_BPS`, default 0).
- openmaru never receives, holds, or transfers donor funds. KYC data is collected by Stripe; openmaru stores only account status.
- MVP: USD only, card payments only (`payment_method_types: ["card"]`), one-time and monthly recurring. Min $1.00, max $10,000.00 per donation, whole cents.

## 2. Who may manage payments

**Org administrators** = effective holders of the circle named in the active spec's `amend` procedure (if `amend` uses `members`, every effective holder of any circle). Only administrators can start onboarding or view reconciliation.

## 3. Onboarding

Tables: `stripe_accounts(org_id unique, account_id unique, charges_enabled, payouts_enabled, details_submitted, requirements jsonb, disabled_reason, synced_at)`.

1. `POST /api/v1/orgs/:slug/payments/onboarding` (admin) → create the connected account if none, create an Account Link (`type=account_onboarding`, refresh/return URLs to the web app) → `{url}`.
2. `account.updated` (Connect webhook) → upsert status fields.
3. `GET /api/v1/orgs/:slug/payments/status` → status + human summary of `requirements.currently_due`.
4. Donations are refused with `payments_not_enabled` unless `charges_enabled`.

## 4. Donations

Table `donations`: `id`, `org_id`, `goal_id null` (null = treasury), `amount_micros`, `recurring` (`none/monthly`), `parent_donation_id null` (renewals), `status` (`pending/succeeded/refunded/partially_refunded/disputed/refund_unfunded/expired`), `checkout_session_id`, `payment_intent_id`, `charge_id`, `subscription_id`, `invoice_id`, `stripe_fee_micros`, `platform_fee_micros`, `refunded_micros`, `donor_display_name null`, `donor_public bool`, `receipt_token_hash`, timestamps.

### 4.1 Checkout
`POST /api/v1/donations/checkout {org, goal_id?, amount_micros, recurring, donor_display_name?, donor_public}` (no auth required; rate-limited 10/min/IP):
- Validate org/goal (goal must be `active`, `underfunded`, or `paused`; not `closed`), amount bounds, payments enabled.
- Insert `pending` donation with a random receipt token (only its hash stored).
- Create Checkout Session on the connected account:
  - `mode=payment`: one `price_data` line (`currency=usd`, `unit_amount` = cents, product name `Donation to <goal title | org name>`), `payment_intent_data.application_fee_amount = floor(cents × bps / 10_000)`, `payment_intent_data.metadata` and session `metadata = {donation_id, org_id, goal_id}`.
  - `mode=subscription`: `price_data.recurring.interval=month`, `subscription_data.application_fee_percent = bps/100`, `subscription_data.metadata` as above.
  - `success_url = <web>/donations/<donation_id>/thanks?t=<receipt token>`, `cancel_url` back to the goal page. Session expiry 30 min (`checkout.session.expired` → donation `expired`).
- Return `{checkout_url, donation_id}`.

### 4.2 Webhooks
Endpoints: `POST /webhooks/stripe` (platform) and `POST /webhooks/stripe/connect` (connected accounts; `event.account` set). Each has its own signing secret; invalid signature → 400. Events are stored in `stripe_events(id unique, type, account, payload, processed_at, error)`; duplicates are acknowledged and skipped. Processing happens in an Oban job (retry with backoff); the endpoint returns 200 after storing.

| Event | Handling |
|---|---|
| `account.updated` | §3 |
| `checkout.session.completed` (`mode=payment`, `payment_status=paid`) | Retrieve PaymentIntent on the connected account with `latest_charge.balance_transaction` expanded. From `fee_details`: `stripe_fee` and `application_fee`. Mark donation `succeeded`; write the ledger chain (§5); emit `donation.received`. |
| `checkout.session.completed` (`mode=subscription`) | Store `subscription_id` on the donation; money is recorded on `invoice.paid`. |
| `invoice.paid` (subscription) | First invoice → complete the original donation; later invoices → new donation row with `parent_donation_id`. Same ledger chain. |
| `charge.refunded` | For each refund object not yet processed: ledger refund (§5); update `refunded_micros` and status. |
| `charge.dispute.created` | status `disputed`; alert administrators. No ledger change. |
| `charge.dispute.closed` (`lost`) | Treat disputed amount like a refund. |
| `checkout.session.expired` | donation `expired` |
| `customer.subscription.deleted` | mark the recurring series ended |

### 4.3 Receipts and privacy
- `GET /api/v1/donations/:id/receipt?t=<token>` → amount, fees, net to goal, goal link, and the goal's spend since the donation (pooled; not per-cent attribution).
- openmaru stores no donor email or payment details. Public activity shows amount and, only if `donor_public`, the display name.

## 5. Ledger mapping (SPEC-03 §5.5)

Destination account `D` = `goal:<g>:funds` or `org:<o>:treasury`. Fee accounts are the goal's `spend:fees_*` or the org's `fees_*` accordingly. Linked chain:
1. `org:<o>:ext_donations` → `D`, gross, code 1, id `uuidv5("donation:<charge_id>")`, `user_data_128 = donation_id`
2. `D` → fees_stripe, code 2, id `uuidv5("fee_stripe:<charge_id>")` (omitted if 0)
3. `D` → fees_platform, code 3, id `uuidv5("fee_platform:<charge_id>")` (omitted if 0)

Fees also create `spend_records` with `source=stripe`, tier `verified`. Treasury donations trigger goal top-ups (SPEC-03 §5.3). Refunds: `D` → `ext_refunds`, id `uuidv5("refund:<refund_id>")`, fallback to treasury, else `refund_unfunded` + alert. Processing fees are not returned by Stripe on refunds and stay recorded as spent.

## 6. Reconciliation

Daily Oban job at 02:00 UTC per connected account for the previous UTC day: list balance transactions (`type` in `charge`, `refund`, `adjustment`, `payment`) and compare against ledger transfers with codes 1–4 for that account and day (matched by charge/refund IDs). Store `reconciliation_runs(org_id, date, status ok|mismatch|error, details jsonb)`. Mismatches alert org administrators and platform admins. The job never modifies the ledger.

## 7. Client abstraction

`Openmaru.Payments.StripeClient` behaviour wraps every Stripe call (`create_account/1`, `create_account_link/2`, `create_checkout_session/2`, `retrieve_payment_intent/2`, `list_refunds/2`, `list_balance_transactions/2`, `construct_event/3`). Production uses `stripity_stripe`; tests use Mox. E2E tests (H01) use Stripe test mode.
