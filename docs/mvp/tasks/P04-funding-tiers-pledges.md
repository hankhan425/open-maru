# P04 · Funding tiers, accepted spend, pledges, caps

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P02, M02, A02, G03 | L | 12 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-05 §1, §4, §8.1–§8.4, §8.6, §8.10–§8.11; SPEC-03 §3, §5.5–§5.7; SPEC-02 §3.1 (E505–E507), §3.4, §6; SPEC-07 payments rows.
**Paths:** `lib/openmaru/funding/**`, `lib/openmaru/payments/pledges/**`, controllers, migrations, Oban workers

## Goal
Outside money is earned, not assumed. An org spends its own money until it has a track record. Then donors pledge to pay back accepted work, which leaves nothing to run off with. Later the org may take upfront donations, capped at about three months of its accepted spend.

## Deliverables
- **Tiers.** `Openmaru.Funding.Tiers`: `evaluate/1` (daily Oban job and after every version activation), per-org tier and per-goal conditions (SPEC-05 §8.1), and `GET /orgs/:slug/funding`. No admin override; dev and e2e seeds may backdate history (H01).
- **Accepted spend.** `Openmaru.Funding.accepted_spend(goal, month)` (SPEC-05 §8.2).
- **Outside-money lots** (SPEC-05 §8.4). Migration `outside_money_lots`.
  - A donation becomes a lot when it succeeds.
  - Posted spend of the goal consumes lots oldest first.
  - Refunds reduce their lot.
  - `rebuild_lots/1` derives the same table from donations, refunds and spend records.
- **Gates.**
  - Checkout refuses with 409 `funding_tier_required` or 409 `outside_money_cap_reached`.
  - Monthly donations pause (`pause_subscription`) while a goal is at its cap, and resume below it.
- **Money-safety checks.** E505–E507 (SPEC-05 §8.6) as server validation for orgs with a goal at tier 2. They are run by `Orgs.check_source/2` and by proposal creation (C04).
- **Receipts for expenses.** An expense claim on a goal with unspent outside money needs a receipt: 422 `validation_failed` with `details.reason: "receipt_required"` (extends G03).
- **Pledges** (SPEC-05 §8.3).
  - Migrations `pledges` and `pledge_charges`.
  - Setup through a platform Checkout session in `setup` mode; the pledge becomes active on the platform webhook.
  - The monthly charge job (1st, 03:00 UTC; idempotent per goal and month): an 80% share of accepted spend, split pro rata by caps, whole cents, amounts under $0.50 carried over.
  - Off-session direct charges with a cloned card; the ledger chain of SPEC-03 §5.7 (codes 101/310 and transfer codes 5/6 are added to `Openmaru.Ledger` if it lists codes).
  - Pledge page, cancel and reconfirm endpoints; `failing` after 3 failed charges.
- **Events:** `pledge.created`, `pledge.charged`, `pledge.cancelled`.

## Tests to write first
- [ ] **P04-T01** Tier 1:
  - An org 29 days old → tier 0.
  - At 30 days, with 3 accepted tasks, $100 of accepted spend and `charges_enabled` → tier 1.
  - Spend on a task accepted by the claimant agent's operator doesn't count.
- [ ] **P04-T02** Accepted spend counts in September: verified spend on a task accepted in September, even if the spend posted in August. Excluded: spend on a rejected task, spend with no task, `attested` and `evidenced` spend.
- [ ] **P04-T03** Tier 2:
  - 90 days at tier 1 with accepted spend in each of the last 3 months, and a spec passing E505–E507 → org tier 2.
  - A goal whose steward circle has 1 qualifying holder can't take donations. A holder doesn't qualify when silent, when their account is under 90 days old, or without a linked GitHub/Google identity.
  - A goal with no accepted spend in 90 days can't take donations, nor can one whose amend rule is `approve(core, 1)`.
- [ ] **P04-T04** Checkout:
  - A tier-1 goal → 409 `funding_tier_required`.
  - A tier-2 goal within its cap → session created.
  - One that would exceed the cap → 409 `outside_money_cap_reached`.
  - A treasury destination → 422.
- [ ] **P04-T05** Lots:
  - Donations of $100 then $50, then $120 of spend → remaining [0, 30], U = $30. A $20 refund of the second → U = $10.
  - Property: random donations, spend and refunds give the same lots incrementally as `rebuild_lots/1`, and spend never consumes own funds while a lot remains.
- [ ] **P04-T06** Cap:
  - It equals 3 × the average monthly accepted spend of the trailing 90 days.
  - At the cap, monthly donations pause (mock); after spend lowers U, they resume.
- [ ] **P04-T07** Money-safety checks:
  - A proposal in a tier-2 org gets E505 for a spend mandate without `expires` or expiring in 91 days, E506 for `else allow` on `amend` or a spend rule, and E507 for an expense line without an approval rule.
  - The same proposal in a tier-1 org passes.
- [ ] **P04-T08** An expense without a receipt on a goal with U > 0 → 422 `receipt_required`. With U = 0 → posted `attested` as before.
- [ ] **P04-T09** Pledge setup:
  - Creates a platform `setup` session (mock); the pledge is `pending` until the webhook, then `active`.
  - The cap is outside $1–$10,000 → 422. The goal is below tier 1 → 409 `funding_tier_required`. Rate limit as checkout.
- [ ] **P04-T10** Monthly charge:
  - Accepted spend $1,000 and caps $500 + $1,000 → charges $266.66 and $533.33. Each is an off-session direct charge on the connected account with a cloned card and the application fee (mocks).
  - Ledger chain code 6 into `goal:<g>:reimbursed`, plus fee transfers. The pledge page lists the tasks and spend each charge paid for.
- [ ] **P04-T11** Accepted spend $10,000 and caps totalling $1,500 → each pledge pays its cap.
- [ ] **P04-T12** Charge lifecycle:
  - A share under $0.50 carries over to the next month.
  - Rerunning the job charges nothing new.
  - A cancelled pledge is not charged.
  - 3 failed charges → `failing`, skipped.
- [ ] **P04-T13** Pledge money never funds spend: goal funds are unchanged by a pledge charge, and with only `reimbursed` money, a spend → `goal_funds_insufficient`.
- [ ] **P04-T14** `GET /orgs/:slug/funding`: tier, each goal's conditions (met or not, with the reason), U, cap, pledged caps, and the liveness clock fields P05 fills.

## Out of scope
Waiting periods, donor exits, dormancy, payments continuity, pledges moving to forks (P05). The giving UI (F07).
