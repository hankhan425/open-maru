# SPEC-05 — Payments (Stripe Connect)

## 1. Model (ADR-2, non-custodial)

- Each org connects its **own** Stripe account as a Connect account with full Stripe Dashboard access (the classic `type=standard`; with controller properties: Stripe collects requirements, the connected account pays fees and bears losses).
- Donations are **direct charges** created on the connected account (`Stripe-Account` header). The org is merchant of record. openmaru takes an optional **application fee** (`PLATFORM_FEE_BPS`, default 0).
- openmaru never receives, holds, or transfers donor funds. KYC data is collected by Stripe; openmaru stores only account status.
- MVP: USD only, card payments only (`payment_method_types: ["card"]`), one-time and monthly recurring. Min $1.00, max $10,000.00 per donation, whole cents.
- **Outside money** (pledges and donations, from anyone through openmaru) is accepted only under the funding tiers and donor protections of §8. An org that spends only its **own funds** (SPEC-03 §5.6) needs no Stripe account at all.

## 2. Who may manage payments

**Org administrators** = effective holders of the circle named in the active spec's `amend` procedure (if `amend` uses `members`, every effective holder of any circle). Only administrators can start onboarding or view reconciliation.

## 3. Onboarding

Tables: `stripe_accounts(org_id unique, account_id unique, charges_enabled, payouts_enabled, details_submitted, requirements jsonb, disabled_reason, synced_at)`.

1. `POST /api/v1/orgs/:slug/payments/onboarding` (admin) → create the connected account if none (or a replacement when §8.8 allows one), record the administrator as `connected_by_user_id`, create an Account Link (`type=account_onboarding`, refresh/return URLs to the web app) → `{url}`.
2. `account.updated` (Connect webhook) → upsert status fields.
3. `GET /api/v1/orgs/:slug/payments/status` → status + human summary of `requirements.currently_due`.
4. Donations are refused with `payments_not_enabled` unless `charges_enabled`.

## 4. Donations

Table `donations`: `id`, `org_id`, `goal_id` (always a goal: the treasury takes no outside money, §8.4), `amount_micros`, `recurring` (`none/monthly`), `parent_donation_id null` (renewals), `status` (`pending/succeeded/refunded/partially_refunded/disputed/refund_unfunded/expired`), `checkout_session_id`, `payment_intent_id`, `charge_id`, `subscription_id`, `invoice_id`, `stripe_fee_micros`, `platform_fee_micros`, `refunded_micros`, `donor_display_name null`, `donor_public bool`, `receipt_token_hash`, timestamps.

### 4.1 Checkout
`POST /api/v1/donations/checkout {org, goal_id, amount_micros, recurring, donor_display_name?, donor_public}` (no auth required; rate-limited 10/min/IP):
- Validate org/goal (goal must be `active`, `underfunded`, or `paused`; not `closed`), amount bounds, payments enabled.
- The goal must take upfront donations (§8.1; else 409 `funding_tier_required`) and stay within its cap (§8.4; else 409 `outside_money_cap_reached`).
- Insert `pending` donation with a random receipt token (only its hash stored).
- Create Checkout Session on the connected account:
  - `mode=payment`: one `price_data` line (`currency=usd`, `unit_amount` = cents, product name `Donation to <goal title>`), `payment_intent_data.application_fee_amount = floor(cents × bps / 10_000)`, `payment_intent_data.metadata` and session `metadata = {donation_id, org_id, goal_id}`.
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

Destination account `D` = `goal:<g>:funds` (donations always name a goal, §8.4). Fee accounts are the goal's `spend:fees_*`. Linked chain:
1. `org:<o>:ext_donations` → `D`, gross, code 1, id `uuidv5("donation:<charge_id>")`, `user_data_128 = donation_id`
2. `D` → fees_stripe, code 2, id `uuidv5("fee_stripe:<charge_id>")` (omitted if 0)
3. `D` → fees_platform, code 3, id `uuidv5("fee_platform:<charge_id>")` (omitted if 0)

Fees also create `spend_records` with `source=stripe`, tier `verified`. Pledge charges use SPEC-03 §5.7 instead. Refunds: `D` → `ext_refunds`, id `uuidv5("refund:<refund_id>")`, fallback to treasury, else `refund_unfunded` + alert. Processing fees are not returned by Stripe on refunds and stay recorded as spent.

## 6. Reconciliation

Daily Oban job at 02:00 UTC per connected account for the previous UTC day: list balance transactions (`type` in `charge`, `refund`, `adjustment`, `payment`) and compare against ledger transfers with codes 1–4 for that account and day (matched by charge/refund IDs). Store `reconciliation_runs(org_id, date, status ok|mismatch|error, details jsonb)`. Mismatches alert org administrators and platform admins. The job never modifies the ledger.

## 7. Client abstraction

`Openmaru.Payments.StripeClient` behaviour wraps every Stripe call (`create_account/1`, `create_account_link/2`, `create_checkout_session/2`, `retrieve_payment_intent/2`, `list_refunds/2`, `list_balance_transactions/2`, `construct_event/3`; for §8: `create_setup_session/1`, `clone_payment_method/3`, `create_off_session_charge/3`, `create_refund/3`, `pause_subscription/3`, `cancel_subscription/2`). Production uses `stripity_stripe`; tests use Mox. E2E tests (H01) use Stripe test mode.

## 8. Outside money (OQ-16)

Owners and holders may leave or go silent at any time, so the rules below protect the people who give money instead of binding the people who receive it. They apply only to **outside money**: pledges and donations through openmaru. An org that spends only its own funds has no rules beyond its spec. Every rule here is a platform rule that a spec cannot loosen (§8.10).

### 8.1 Funding tiers
An org earns a tier; each goal takes outside money only while its own conditions also hold. A tier also needs the conditions of the tiers below it. Conditions are checked daily and whenever a version activates. Money a goal already holds stays under §8.4–§8.9 when a condition fails.

| Tier | Takes | The org must have | Each goal must have |
|---|---|---|---|
| 0 Self-funded | own funds | — | — |
| 1 Pledges | own funds, pledges (§8.3) | existed ≥ 30 days; ≥ 3 accepted tasks and ≥ $100 of accepted spend (§8.2) in total; Stripe `charges_enabled` and its connector available (§8.8) | steward activity within the last 45 days (§8.7) |
| 2 Upfront donations | also one-time and monthly donations (§4) | Tier 1 for ≥ 90 days, with accepted spend in each of the last 3 calendar months; an active spec that passes E505–E507 (§8.6) | ≥ 2 effective steward holders (SPEC-02 §3.4) whose accounts are ≥ 90 days old and have a linked GitHub or Google identity; accepted spend in the trailing 90 days; an `amend` procedure that cannot pass with a single yes vote, given the current eligible voters |

Nobody grants a tier by hand in production, platform admins included. Dev and e2e seeds may backdate history (H01). `GET /orgs/:slug/funding` shows the tier, each goal's conditions and outside money, and the liveness clock (§8.7).

### 8.2 Accepted spend
A goal's **accepted spend** is its posted `verified` spend (gateway and runtime, SPEC-03 §6) on tasks accepted by a steward holder other than the task's claimant and the claimant agent's operator (SPEC-02 §6.1). It counts in the calendar month (UTC) the task was accepted. Spend without a task, on rejected or cancelled tasks, or of tier `evidenced` or `attested`, is not accepted spend.

### 8.3 Pledges (Tier 1)
A pledge is a donor's monthly cap for one goal. Donors pay for accepted work after it is done, and pledge money never funds future spend.
- **Setup.** `POST /pledges/setup` opens Stripe Checkout in `setup` mode on the **platform** account, which saves the card to a platform Customer. openmaru stores the Customer and PaymentMethod ids, the cap ($1–$10,000), a management-token hash, `donor_display_name` and `donor_public`.
- **Monthly charge.** On the 1st of each month (03:00 UTC, idempotent per goal and month), R = the goal's accepted spend in the previous month. Pledges cover at most **80%** of R; the org pays the rest. Each active pledge pays `min(cap, floor(0.8 × R × cap / Σ caps))` in whole cents. Amounts under $0.50 carry to the next month. A charge is an off-session direct charge on the org's connected account, with a clone of the saved card and the same application fee as donations.
- **Ledger.** SPEC-03 §5.7: pledge money lands in `goal:<g>:reimbursed`, never in goal funds.
- **Receipt.** The pledge page (`GET /pledges/:id?t=`) lists each charge with the tasks and spend it paid for.
- **Cancel** at any time (`POST /pledges/:id/cancel?t=`); nothing more is charged. After 3 failed charges a pledge is `failing` and skipped.
- **Pause.** Pledges pause when §8.7 or §8.8 says so. A pledge paused for 90 days or more charges again only after the donor reconfirms (`POST /pledges/:id/reconfirm?t=`).

### 8.4 Upfront donations (Tier 2)
Donations are earmarked to a goal; the treasury takes no outside money.
- **Unspent outside money (U).** Each succeeded donation is a lot. A goal's posted spend consumes its lots oldest first, before any own funds; a refund reduces its lot. U = the sum of the goal's remaining lots. Lots live in a control-plane table that can be rebuilt from donations, refunds and spend records.
- **Cap.** U may not exceed 3 × the goal's average monthly accepted spend over the trailing 90 days. A checkout that would exceed it gets 409 `outside_money_cap_reached`. While U is at the cap, monthly donations to the goal pause (Stripe `pause_collection`) and resume when it drops.
- **Expenses.** An expense claim against a goal with U > 0 needs a receipt (`validation_failed`, `details.reason: "receipt_required"`) and goes through an approval rule (E507).

### 8.5 Waiting period and donor exit
While the org holds outside money (U > 0 in any goal), an amendment that passes takes effect **14 days** later, unless every change in its diff (SPEC-01 §9) is `tightens`.
- The version is `scheduled` with `activates_at`; spending continues under the active version (SPEC-02 §4.4).
- During the wait, a donor with an unspent lot in the org may exit: `POST /donations/:id/exit?t=` refunds that lot's remainder on its original charge and cancels the donor's monthly series. Outside the wait → 409 `exit_not_open`.
- At `activates_at` the version activates, unless the active version changed in the meantime: it is then `stale`.
- Pledges are not held back: they pay only for past accepted work and can be cancelled at any time. The pledge page shows the scheduled change.

### 8.6 Money-safety checks
For an org with a goal at Tier 2, server validation (SPEC-02 §3.1) adds three codes. The active spec must pass them to enter Tier 2, and every proposal must pass them while the org is there.
- **E505:** a mandate with a spend line in such a goal has no `expires`, or one more than 90 days after the proposal. Spending power is a lease that only an amendment renews.
- **E506:** `else allow` on `amend` or on a spend rule of such a goal.
- **E507:** such a goal has an `expense` spend line that is not covered by a rule requiring approval of every expense (`rule spend expense requires …` or `rule spend requires …`, with no amount and `else deny`).

### 8.7 Liveness and dormancy
A goal that holds outside money (U > 0) or has active pledges is watched. Its **steward activity** is the latest `last_active_at` (SPEC-02 §2) among its steward circle's accepted, listed holders.

| Days without steward activity | Effect |
|---|---|
| 30 | Warning on the goal page and on donors' receipt and pledge pages; `goal.dormancy_warning` |
| 45 | Checkout closes for the goal; its monthly donations and pledge charges pause |
| 60 | The goal pauses (`pause_reason: dormant`): spend refused with `goal_paused`, holds voided, sessions stopped |
| 90 | The goal is dormant: every unspent lot is refunded on its charge, monthly donations are cancelled, pledges stay paused; `goal.dormant` |

Steward activity before day 90 resets the clock; from day 60 a steward must also resume the goal. After day 90 a steward can resume it: pledges need reconfirmation (§8.3) and donations reopen if the tiers allow. A refund that fails (the account lacks balance, or the charge can no longer be refunded) is recorded as `refund_unfunded` (§4.2) and shown publicly.

### 8.8 Payments continuity
One administrator connects the Stripe account (`stripe_accounts.connected_by_user_id`). If that person leaves the org, is suspended or deleted, or is silent for 45 days:
- checkout closes for the org, and monthly donations and pledge charges pause;
- any active administrator may connect a replacement account (§3), and the old account is kept for refunds and reconciliation;
- pledges resume on the new account (their cards are saved on the platform), while monthly donations on the old account are cancelled and their donors asked to start again.

Money already paid out from the old account is beyond openmaru's reach (§8.11).

### 8.9 Closing, forks and the public record
- Closing a goal that holds outside money refunds every unspent lot before `on_close` moves the rest, which is own funds.
- A donor may move a pledge to a goal of a fork (SPEC-02 §3.7) created by someone who was a member of the original org when they forked it (`POST /pledges/:id/move?t=`). It charges once the fork reaches Tier 1.
- When a goal goes dormant holding outside money, its goal and org pages show permanently: the date, the amounts refunded and unrefunded, and the handles of its steward holders at the time.

### 8.10 What a spec can change
Nothing in §8 is a spec setting in the MVP. Later, an org may make the values in §8.3–§8.7 stricter (a smaller pledge share, a lower cap, a longer wait, shorter leases or liveness steps), never looser. Rules that only affect the org's own people (the silence window, amend shrinking, member-vote turnout; SPEC-01 §4.7, SPEC-02 §3.4, §4.1) may become settings within bounds.

### 8.11 What these rules cannot do
Payments are non-custodial (§1): openmaru cannot hold, freeze or claw back money in an org's Stripe account or bank, so refunds are best effort. The rules bound what outsiders can lose and make every loss public:
- **Pledges:** outsiders lose nothing ahead of accepted work.
- **Upfront donations:** outsiders lose at most a goal's cap, about 3 months of its accepted spend.

