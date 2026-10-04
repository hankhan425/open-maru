# SPEC-05 — Payments (Stripe Connect)

## 1. Model (ADR-2, non-custodial)

- Each org connects its **own** Stripe account as a Connect account with full Stripe Dashboard access (the classic `type=standard`; with controller properties: Stripe collects requirements, the connected account pays fees and bears losses).
- Donations are **direct charges** created on the connected account (`Stripe-Account` header). The org is merchant of record. openmaru takes an optional **application fee** (`PLATFORM_FEE_BPS`, default 0).
- openmaru never receives, holds, or transfers donor funds. KYC data is collected by Stripe; openmaru stores only account status.
- MVP: USD only, card payments only (`payment_method_types: ["card"]`), one-time and monthly recurring. Min $1.00, max $10,000.00 per donation, whole cents.
- **Outside money** (pledges and donations, from anyone through openmaru) is protected by the guarantees of §8, and pays for accepted work at cost plus the org's margin. An org that spends only its **own funds** (SPEC-03 §5.6) needs no Stripe account at all.

## 2. Who may manage payments

**Org administrators** = effective holders of the circle named in the active spec's `amend` procedure (if `amend` uses `members`, every effective holder of any circle). Only administrators can start onboarding or view reconciliation.

## 3. Onboarding

Tables: `stripe_accounts(org_id, account_id unique, connected_by_user_id, display_name null, country null, charges_enabled, payouts_enabled, details_submitted, requirements jsonb, disabled_reason, replaced_at null, synced_at)`; at most one row per org has `replaced_at` null (the current account).

1. `POST /api/v1/orgs/:slug/payments/onboarding` (admin) → create the connected account if none (or a replacement when §8.8 allows one), record the administrator as `connected_by_user_id`, create an Account Link (`type=account_onboarding`, refresh/return URLs to the web app) → `{url}`.
2. `account.updated` (Connect webhook) → upsert status fields, and `display_name` (`business_profile.name`, else `settings.dashboard.display_name`) and `country` for §8.9.
3. `GET /api/v1/orgs/:slug/payments/status` → status + human summary of `requirements.currently_due`.
4. Donations are refused with `payments_not_enabled` unless `charges_enabled`.

## 4. Donations

Table `donations`: `id`, `org_id`, `goal_id` (always a goal: the treasury takes no outside money, §8.3), `amount_micros`, `margin_bps` (the org's margin when the donation was made, §8.3), `recurring` (`none/monthly`), `parent_donation_id null` (renewals), `status` (`pending/succeeded/refunded/partially_refunded/disputed/refund_unfunded/expired`), `checkout_session_id`, `payment_intent_id`, `charge_id`, `subscription_id`, `invoice_id`, `stripe_fee_micros`, `platform_fee_micros`, `refunded_micros`, `donor_display_name null`, `donor_public bool`, `receipt_token_hash`, timestamps.

### 4.1 Checkout
`POST /api/v1/donations/checkout {org, goal_id, amount_micros, recurring, donor_display_name?, donor_public}` (no auth required; rate-limited 10/min/IP):
- Validate org/goal (goal must be `active`, `underfunded`, or `paused`; not `closed`), amount bounds, payments enabled.
- The goal must be taking outside money (§8.7, §8.8; else 409 `not_accepting_money` with `details.reason`), and the amount must fit its cap or the org's starting allowance (§8.5; else 409 `outside_money_cap_reached`).
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
| `invoice.paid` (subscription) | First invoice → complete the original donation; later invoices → new donation row with `parent_donation_id` and the series' first `margin_bps` (§8.3). Same ledger chain. |
| `charge.refunded` | For each refund object not yet processed: ledger refund (§5); update `refunded_micros` and status. |
| `charge.dispute.created` | status `disputed`; alert administrators. No ledger change. |
| `charge.dispute.closed` (`lost`) | Treat disputed amount like a refund. |
| `checkout.session.expired` | donation `expired` |
| `customer.subscription.deleted` | mark the recurring series ended |

### 4.3 Receipts and privacy
- `GET /api/v1/donations/:id/receipt?t=<token>` → amount, its cost and margin parts, fees, goal link, the recipient (§8.9), and the money trace of its lot (§8.11): the spend it paid for with tasks and evidence, the margin earned from it, and what remains.
- openmaru stores no donor email or payment details. Public activity shows amount and, only if `donor_public`, the display name.

## 5. Ledger mapping (SPEC-03 §5.5)

Destination account `D` = `goal:<g>:funds` (donations always name a goal, §8.3); `M` = `goal:<g>:margin_held`. The gross splits into a margin part, `floor(gross × margin_bps / (10_000 + margin_bps))`, and a cost part (the rest). Fee accounts are the goal's `spend:fees_*`. Linked chain:
1. `org:<o>:ext_donations` → `D`, cost part, code 1, id `uuidv5("donation:<charge_id>")`, `user_data_128 = donation_id`
2. `org:<o>:ext_donations` → `M`, margin part, code 8, id `uuidv5("donation_margin:<charge_id>")` (omitted if 0)
3. `D` → fees_stripe, code 2, id `uuidv5("fee_stripe:<charge_id>")` (omitted if 0)
4. `D` → fees_platform, code 3, id `uuidv5("fee_platform:<charge_id>")` (omitted if 0)

Fees also create `spend_records` with `source=stripe`, tier `verified`; they are spend of the goal and use the donation's lot like any other (§8.3). Pledge charges use SPEC-03 §5.7 instead. Refunds of a lot: the refund splits between cost and margin in proportion to the lot's remainders; `D` → `ext_refunds` and `M` → `ext_refunds`, code 4, ids `uuidv5("refund:<refund_id>")` and `uuidv5("refund_margin:<refund_id>")`; if `D` lacks the balance (held spend), the cost part falls back to the treasury, else `refund_unfunded` + alert. Processing fees are not returned by Stripe on refunds and stay recorded as spent.

## 6. Reconciliation

Daily Oban job at 02:00 UTC per connected account for the previous UTC day: list balance transactions (`type` in `charge`, `refund`, `adjustment`, `payment`) and compare against the ledger for that account and day, matched by charge/refund IDs: each charge's gross with the sum of its inflow transfers (codes 1 and 8 for a donation, 6 and 7 for a pledge charge), each fee with codes 2–3, each refund with its code-4 transfers. Store `reconciliation_runs(org_id, date, status ok|mismatch|error, details jsonb)`. Mismatches alert org administrators and platform admins. The job never modifies the ledger.

## 7. Client abstraction

`Openmaru.Payments.StripeClient` behaviour wraps every Stripe call (`create_account/1`, `create_account_link/2`, `create_checkout_session/2`, `retrieve_payment_intent/2`, `list_refunds/2`, `list_balance_transactions/2`, `construct_event/3`; for §8: `create_setup_session/1`, `clone_payment_method/3`, `create_off_session_charge/3`, `create_refund/3`, `pause_subscription/3`, `cancel_subscription/2`). Production uses `stripity_stripe`; tests use Mox. E2E tests (H01) use Stripe test mode.

## 8. Outside money (OQ-16)

People may leave or go silent at any time, and payments are non-custodial (§1): whoever controls an org's Stripe account can withdraw its balance, and openmaru cannot stop or reverse that. So the platform **guarantees** a few things about outside money and **shows** everything else. The guarantees (§8.2–§8.9) are platform rules that a spec cannot loosen. What an org chooses (its rules, its margin, who reviews work, who is paid) is computed from its spec and history and shown to supporters (§8.11), who judge for themselves. Outside money can pay the full cost of accepted work plus the org's margin, so an org can sustain itself on it alone. An org that spends only its own funds has no rules beyond its spec.

### 8.1 Terms
- **Outside money:** donations and pledge charges through openmaru. **Own funds** are what an administrator records the org putting in itself (SPEC-03 §5.6, `attested`).
- **Accepted spend** of a goal: its posted `verified` spend (SPEC-03 §6) that is not `estimated` (SPEC-06 §3.4), on tasks accepted under SPEC-02 §6.1 (by a steward holder other than the claimant and the claimant agent's operator). It counts in the UTC calendar month the task was accepted, or the month the spend posted if that is later. Spend without a task, on a task not accepted, or of tier `evidenced` or `attested`, is not accepted spend.
- **Lots and U:** each succeeded donation is a lot (§8.3). A goal's **unspent outside money (U)** is the sum of its lots' remainders, unearned margin included.
- **Margin:** the org's markup on accepted work that outside money pays for (SPEC-01 §4.9). With `margin: 15%`, supporters pay $1.15 for each $1 of accepted spend, and $0.15 goes to the org's earnings (§8.10). A gift never pays a higher margin than the one in force when it was given, and pays the current one when that is lower.
- **Earned money:** outside money that has paid for accepted work. It belongs to the org: cost goes to the treasury (pledges, §8.4) or has already been spent (lots, §8.3), and margin goes to earnings (§8.10).

### 8.2 Honest meter
Only spend measured where openmaru can vouch for it is `verified`: gateway calls, hosted-runtime time, and Stripe fees (SPEC-03 §6). The gateway reaches only provider endpoints on a list that platform admins keep, each priced on its own (SPEC-06 §2), so an org cannot run a server that reports usage nobody was billed for. Anything else is a claim and labelled as one:
- An expense claim on a goal with U > 0 needs a receipt: 422 `validation_failed`, `details.reason: "receipt_required"`.
- Spend posted as `estimated` (the full hold, SPEC-06 §3.4) stays `verified` but is not accepted spend.

### 8.3 Earmarking, lots and margin
Outside money always names a goal (the treasury takes none, §4.1) and pays only for that goal.
- **Lots.** Table `outside_money_lots(goal_id, donation_id, margin_bps, cost_micros, cost_remaining_micros, margin_micros, margin_remaining_micros)`. A donation's gross splits on arrival (§5): the margin part goes to `goal:<g>:margin_held`, the cost part to the goal's funds. `margin_bps` is the org's margin when the donation was made (a monthly series keeps its first one).
- **Spending.** A goal's posted spend (Stripe fees included) uses its lots' cost oldest first, before any own or earned money. `lot_consumptions(lot_id, spend_record_id, micros, margin_earned_micros)` record which lot paid for which spend. A refund reduces its lot (§5). The lot tables can be rebuilt from donations, refunds, spend records and tasks.
- **Earning margin.** When spend that a lot paid for becomes accepted spend (its task is accepted, or it posts on an already accepted task), that lot's margin for it, `floor(consumed × bps / 10_000)` with bps the lower of the lot's and the org's current margin, capped by the lot's margin remaining, moves to the org's earnings (SPEC-03 §5.8).
- Margin on spend that never becomes accepted is never earned: it stays in the lot and is refunded with it (§8.6, §8.7, closing).
- **Closing.** Closing a goal refunds every lot's remainder on its charge before `on_close` moves the rest, which is own or earned money (SPEC-02 §5.3). `on_close: transfer` never moves outside money.

### 8.4 Pledges
A pledge is a donor's monthly cap for one goal. Donors pay for accepted work after it is done.
- **Who takes them.** A goal of an org whose current Stripe account has `charges_enabled` (else `payments_not_enabled`), while §8.7 and §8.8 allow (else 409 `not_accepting_money` with `details.reason`).
- **Setup.** `POST /pledges/setup` opens Stripe Checkout in `setup` mode on the **platform** account, which saves the card to a platform Customer. openmaru stores the Customer and PaymentMethod ids, the cap ($1–$10,000), the org's current margin as the pledge's `margin_bps`, a management-token hash, `donor_display_name` and `donor_public`.
- **Monthly charge.** On the 1st of each month (03:00 UTC, idempotent per goal and month):
  - R = the goal's accepted spend in the previous month that lots did not pay for (§8.3). Pledges never pay for work donations already paid for, so a goal rich in donations charges its pledgers little or nothing.
  - Each active pledge pays `min(cap, floor(R × (10_000 + bps) × cap / (10_000 × Σ caps)))` in whole cents, with bps the lower of the pledge's and the org's current margin. Amounts under $0.50 carry to the next month. What pledges don't cover has already been paid by the org.
  - The charge's margin part is `floor(charge × bps / (10_000 + bps))`; the rest is its cost part.
  - A charge is an off-session direct charge on the org's current connected account, with a clone of the saved card and the same application fee as donations.
- **Ledger.** SPEC-03 §5.7: the cost part goes to the treasury and the margin part to earnings. Both are earned money.
- **Receipt.** The pledge page (`GET /pledges/:id?t=`) lists each charge with the tasks and spend it paid for, its margin part, and the accepted spend that donations had already paid for.
- **Cancel** at any time (`POST /pledges/:id/cancel?t=`); nothing more is charged. After 3 failed charges a pledge is `failing` and skipped.
- **Reconfirm** (`POST /pledges/:id/reconfirm?t=`) adopts the org's current margin. A donor reconfirms to pay a margin that was raised after setup, and after the goal went dormant (§8.7).
- **Pause.** Charges pause while §8.8 says so.

### 8.5 Cap and starting allowance
Upfront money is limited by how much accepted work a goal has shown it turns money into.
- **Cap.** A goal's cap is 10 × its average monthly accepted spend over the trailing 90 days (that spend ÷ 3).
- **Starting allowance.** Whatever the caps, an org may hold up to $1,000 of unspent outside money in total, so a new org can raise its first runway.
- **Checkout** is accepted when, with the new amount, the goal's U stays within its cap or the org's total U stays within $1,000; otherwise 409 `outside_money_cap_reached`. While neither would hold for the goal's monthly donations, they pause (`pause_subscription`) and resume when one does.

### 8.6 Waiting period and donor exit
While the org holds outside money (U > 0 in any goal), an amendment that passes takes effect **14 days** later, unless every change in its diff (SPEC-01 §9) is `tightens`. Raising the margin and adding or raising a pay rule loosen.
- The version is `scheduled` with `activates_at`; spending continues under the active version (SPEC-02 §4.4).
- During the wait, a donor with an unspent lot in the org may exit: `POST /donations/:id/exit?t=` refunds that lot's remainder (cost and unearned margin) on its original charge and cancels the donor's monthly series. Outside the wait → 409 `exit_not_open`.
- At `activates_at` the version activates, unless the active version changed in the meantime: it is then `stale`.
- Pledges are not held back: they pay only for past accepted work, keep their margin until the donor reconfirms (§8.4) and can be cancelled at any time. The pledge page shows the scheduled change.

### 8.7 Liveness and dormancy
A goal with U > 0, an active pledge or an active monthly donation is **watched**. Its **last progress** is the latest of: a task accepted on it, the moment it last became watched, and a steward resuming it from dormancy.

| Days since last progress | Effect |
|---|---|
| 30 | The goal takes no new outside money: checkout and pledge setup → 409 `not_accepting_money` (`details.reason: "no_recent_work"`), and its monthly donations pause. A warning shows on the goal page and on donors' receipt and pledge pages; `goal.dormancy_warning`. |
| 90 | The goal is **dormant** (`dormant_at`, `goal.dormant`): monthly donations are cancelled, and pledges charge again only after the donor reconfirms. If it holds unspent outside money, it also pauses (`pause_reason: dormant`; spend refused with `goal_paused`, holds voided, sessions stopped) and every lot's remainder is refunded on its charge. A goal watched only for pledges keeps working on its own money. |

- An accepted task before day 90 resets the clock and reopens giving.
- A dormant goal refuses checkout and pledge setup with `details.reason: "dormant"`. Dormancy ends when a steward resumes the goal (SPEC-02 §5.2), or, for a goal that did not pause, when a task is accepted on it. Giving then reopens as §8.5 allows.
- A refund that fails (the account lacks balance, or the charge can no longer be refunded) is `refund_unfunded` (§4.2) and shown publicly.
- When a goal goes dormant holding outside money, its goal and org pages show permanently: the date, the amounts refunded and unrefunded, and the handles of its steward holders at the time.

### 8.8 Payments continuity
One administrator connects the org's Stripe account (`stripe_accounts.connected_by_user_id`). While that person has departed the org, is suspended or deleted, or is silent (SPEC-02 §3.4):
- the org takes no new outside money (409 `not_accepting_money`, `details.reason: "connector_unavailable"`), and its monthly donations and pledge charges pause;
- any active administrator may connect a replacement account (§3). The old account gets `replaced_at` and is kept for refunds and reconciliation;
- pledges resume on the new account (their cards are saved on the platform); monthly donations on the old account are cancelled, and their donors are asked to start again.

Refunds go to each charge's own account and are created through the API, so they don't need the connector. Money already paid out from an account is beyond openmaru's reach (§8.13).

### 8.9 Who receives the money
Checkout, pledge setup, receipts and pledge pages show the current account's `display_name` and `country` as Stripe reports them (§3), and the handle of the administrator who connected it. Stripe verifies the identity of an account's owner; openmaru shows only what Stripe returns.

### 8.10 Earnings and pay
- **Earnings** (`org:<o>:earnings`, SPEC-03 §5.8) receive margin earned from lots (§8.3) and the margin part of pledge charges (§8.4). They belong to the org, not to a goal.
- **Pay rules** (SPEC-01 §4.9; `pay @mina 40% <= usd 4_000 / month`) divide each month's earnings.
  - On the 1st of each month (04:00 UTC, after pledge charges; idempotent per org and month), E = earnings credited in the previous month.
  - Each payee who is an active member, neither silent nor suspended, is owed `min(max, floor(E × share / 100))`. A payee who isn't gets nothing for that month.
  - Shares total at most 100% (E327). What is owed moves to `org:<o>:payable` and a `payouts` row (`org_id`, `user_id`, `period_key`, `owed_micros`, `status` `owed/paid`, `proof_upload_id null`, `recorded_by_user_id null`, `paid_at null`); `pay.owed`.
- **Paying** happens off-platform, since openmaru moves no money (§1). An administrator pays the person, then records it with proof: `POST /orgs/:slug/payouts/:id/paid {proof_upload_id}` (an upload with purpose `proof`) moves the amount from payable to `ext_payouts`; `pay.paid`. The record shows who recorded it, including when payees record their own pay.
- **Unclaimed earnings** (what pay rules don't take) stay in earnings. Administrators may move them to the treasury, where they fund goals like own funds: `POST /orgs/:slug/earnings/retain {amount_micros}`; `earnings.retained`.
- Margin is earned only on accepted work: there are no earnings before work is accepted, and unearned margin is refunded with its lot.

### 8.11 What supporters see
`GET /orgs/:slug/funding` and the org, goal and giving pages show, computed from the spec and history:
- **Giving:** for each goal, whether it takes pledges and donations now and, if not, why; U, its cap and the starting allowance in use; the margin.
- **Rules:** the charter, plus flags for an `amend` procedure that one yes vote can pass, anything that passes when nobody acts (`else allow` on `amend` or a spend rule), spend mandates with no `expires` or one more than 90 days away, and expense lines without an approval rule.
- **Track record:** the org's age; accepted tasks and accepted spend by month; the shares of spend that are `verified`, `evidenced` and `attested`.
- **Review:** the people who accepted work in the last 90 days, and which of them are paid by pay rules.
- **Earnings and pay:** the pay rules; earnings, amounts owed and amounts paid, by month; amounts owed for more than 60 days.
- **Liveness:** last progress (§8.7), refunds, failed refunds and dormancy records.
- **Recipient** (§8.9).
- **Money trace:** each donation's receipt follows its lot to the spend it paid for, with tasks and evidence, and the margin earned from it (§4.3); each pledge charge lists the tasks it paid for (§8.4).

### 8.12 What a spec can change
An org sets its margin and pay rules in its spec (SPEC-01 §4.9). Nothing else in §8 is a spec setting in the MVP. Later, an org may make the platform values stricter (a lower cap or allowance, a longer wait, shorter liveness steps), never looser. Rules that only affect the org's own people (the silence window, amend shrinking, member-vote turnout; SPEC-01 §4.7, SPEC-02 §3.4, §4.1) may become settings within bounds.

### 8.13 What these rules cannot do
Payments are non-custodial (§1): openmaru cannot hold, freeze or claw back money in an org's Stripe account or bank, so refunds are best effort. The rules bound what supporters can lose and make every loss public:
- **Pledges:** supporters pay only for accepted work, at cost plus margin, at most their cap each month.
- **Upfront donations:** an org that withdraws its balance and vanishes takes at most its goals' caps (about 10 months of their accepted spend) plus the $1,000 starting allowance.
- **Many orgs:** one person can open several orgs, each with its own $1,000 allowance; each needs its own Stripe account under a verified identity.
- **Margin makes poor work profitable:** margin is earned on whatever the org's reviewers accept. Caps, receipts and the review disclosure (§8.11) bound and show it. A review window in which pledgers drop tasks from their next charge is planned after the MVP.
- **Provider credits and discounts:** when an org's real cost is below catalog price, outside money pays catalog price. Not detected.
- **Second accounts:** one person with two accounts can accept their own agent's work. Stripe's identity checks and the public record are the recourse.
