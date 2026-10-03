# P04 · Outside money: lots, margin, cap, pledges

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P02, M02, A02, G03, L09 | L | 12 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-05 §1, §4, §5, §8.1–§8.5, §8.9, §8.11; SPEC-01 §4.9 (margin); SPEC-03 §3, §5.5, §5.7, §5.8; SPEC-06 §3.1, §3.3 (custom upstream); SPEC-07 payments rows.
**Paths:** `lib/openmaru/funding/**`, `lib/openmaru/payments/pledges/**`, controllers, migrations, Oban workers

## Goal
Outside money pays for accepted work at cost plus the org's margin, and for nothing else. Donations are earmarked lots: spend uses them first, and they earn margin only once the work is accepted. Pledges pay afterwards for the accepted work that donations didn't pay for. A goal holds at most 10 months of its accepted spend, or the org's $1,000 starting allowance. Supporters can see where every dollar went.

## Deliverables
- **Accepted spend.** `Openmaru.Funding.accepted_spend(goal, month)` (SPEC-05 §8.1).
- **Honest meter** (SPEC-05 §8.2).
  - The gateway refuses a call through a custom `openai_base_url` while the goal has U > 0: 403 `custom_upstream_not_allowed` (W03 posts such spend as `attested`).
  - An expense claim on a goal with U > 0 needs a receipt: 422 `validation_failed`, `details.reason: "receipt_required"` (extends G03).
- **Lots and margin** (SPEC-05 §8.3).
  - Migrations `outside_money_lots` and `lot_consumptions`, and `donations.margin_bps`.
  - P02's donation chain gains the margin split: code 8 into `goal:<g>:margin_held`.
  - `Spend.post` uses the goal's lots oldest first.
  - Margin is earned (code 7 into `org:<o>:earnings`) when a task is accepted, and when spend posts on a task that was already accepted.
  - A refund reduces its lot in proportion to cost and margin.
  - `rebuild_lots/1` derives the same tables from donations, refunds, spend records and tasks.
- **Cap and starting allowance** (SPEC-05 §8.5).
  - `Funding.cap(goal)`.
  - Checkout refuses with 409 `outside_money_cap_reached`.
  - Monthly donations pause (`pause_subscription`) while neither the cap nor the allowance would hold, and resume when one does.
- **Pledges** (SPEC-05 §8.4).
  - Migrations `pledges` (with `margin_bps`) and `pledge_charges`.
  - Setup through a platform Checkout session in `setup` mode; the pledge becomes active on the platform webhook.
  - The monthly charge job (1st, 03:00 UTC; idempotent per goal and month):
    - R = accepted spend not paid by lots, plus margin at the lower of the pledge's and the org's rate;
    - split pro rata by caps, whole cents, amounts under $0.50 carried over;
    - the margin part is split out of each charge.
  - Off-session direct charges with a cloned card, and the ledger chain of SPEC-03 §5.7 (codes 6/7; fees from the treasury).
  - Pledge page, cancel and reconfirm (adopts the current margin) endpoints; `failing` after 3 failed charges.
- **What supporters see** (SPEC-05 §8.11). `GET /orgs/:slug/funding`, `Openmaru.Funding.disclosures/1`:
  - per goal: whether it takes pledges and donations (and why not), U, its cap and the allowance in use;
  - the margin and the recipient (SPEC-05 §8.9);
  - reviewers in the last 90 days (P06 marks which are paid);
  - the track record by month;
  - the four rule flags, computed from the IR;
  - the liveness fields that P05 fills.
- **Receipt money trace.** P02's receipt gains the lot's spend, tasks, margin earned and remainder.
- **Events:** `pledge.created`, `pledge.charged`, `pledge.cancelled`.

## Tests to write first
- [ ] **P04-T01** Accepted spend:
  - Counted in September: verified spend on a task accepted in September, even if the spend posted in August.
  - Counted in October: spend that posts in October on a task accepted in September.
  - Excluded: spend on a rejected task, spend with no task, `estimated`, `attested` (a custom upstream, an expense without a receipt) and `evidenced` spend.
- [ ] **P04-T02** Donation split, with `margin: 15%`:
  - A $115 donation sends $100 to goal funds (code 1) and $15 to `margin_held` (code 8); fees come out of goal funds.
  - The lot is cost 100, margin 15, `margin_bps` 1500.
  - Without a margin, everything is cost.
- [ ] **P04-T03** Lots (no margin):
  - Donations of $100 then $50, then $120 of spend → remaining [0, 30], U = $30.
  - A $20 refund of the second → U = $10. Own funds are untouched while a lot remains.
  - Property: random donations, spend, refunds and reviews give the same lots incrementally as `rebuild_lots/1`, and `margin_held` always equals the lots' margin remaining.
- [ ] **P04-T04** Earning margin, with `margin: 15%` and a $115 lot, $40 of spend on a task:
  - Nothing is earned when the spend posts. When the task is accepted, $6 moves from `margin_held` to earnings (code 7), and the lot's margin remaining is $9.
  - Spend on a task that is rejected and then cancelled earns nothing; its margin stays in the lot and is refundable.
  - Spend that posts after its task was accepted earns when it posts.
- [ ] **P04-T05** Rates:
  - A lot made at 15% earns at 10% after the org lowers its margin to 10%, and still at 15% after the org raises it to 20%.
  - A pledge set up at 15% pays 15% after a raise to 20%, until the donor reconfirms.
- [ ] **P04-T06** Cap and allowance, for a goal with $3,000 of accepted spend in the trailing 90 days (cap $10,000):
  - With U = $9,500, a $1,000 checkout → 409 `outside_money_cap_reached`.
  - In a new org with no accepted spend: a $1,000 checkout succeeds under the allowance, and a further $1 → 409.
  - When the cap is reached, monthly donations pause (mock); after spend lowers U, they resume.
- [ ] **P04-T07** Honest meter:
  - A goal with a custom `openai_base_url` and U > 0: a gateway call → 403 `custom_upstream_not_allowed` in the OpenAI envelope. With U = 0, it goes through and posts `attested`.
  - An expense without a receipt on a goal with U > 0 → 422 `receipt_required`. With U = 0 → posted `attested` as before.
- [ ] **P04-T08** Pledge setup:
  - It creates a platform `setup` session (mock). The pledge is `pending` until the webhook, then `active` with the current `margin_bps`.
  - A cap outside $1–$10,000 → 422. `charges_enabled` false → 409 `payments_not_enabled`. Rate-limited like checkout.
- [ ] **P04-T09** Monthly charge:
  - $1,000 of accepted spend that no lot paid for, `margin: 10%`, caps $550 + $550 → each pays $550, of which $50 is margin.
  - Each is an off-session direct charge on the connected account with a cloned card and the application fee (mocks).
  - The same spend with no margin and caps $500 + $1,000 → $333.33 and $666.66.
- [ ] **P04-T10** Donations first:
  - $1,000 of accepted spend of which lots paid $700 → pledges are charged for $300 plus margin.
  - When lots paid for everything, nothing is charged.
  - The pledge page shows the part donations paid for.
- [ ] **P04-T11** $10,000 of accepted spend and caps totalling $1,500 → each pledge pays its cap; the rest is never charged later.
- [ ] **P04-T12** Charge lifecycle:
  - A share under $0.50 carries over to the next month.
  - Rerunning the job charges nothing new.
  - A cancelled pledge is not charged.
  - 3 failed charges → `failing`, then skipped.
- [ ] **P04-T13** Ledger:
  - A pledge charge writes code 6 to the treasury and code 7 to earnings, and the fees go from the treasury to the goal's fee sinks.
  - The treasury credit triggers a top-up.
  - A refund of a pledge charge splits between the treasury and earnings.
- [ ] **P04-T14** `GET /orgs/:slug/funding`:
  - Each goal: whether it takes money (and why not), U, cap, allowance in use, margin.
  - The recipient: display name, country, connector's handle.
  - Reviewers in the last 90 days, and the track record by month.
  - The rule flags for lumen with the Clock at 2026-09-01:
    - `amend` needs more than one yes vote, and nothing has `else allow`: not flagged;
    - jo's mandate has no `expires`, and builder's (2027-01-01) is more than 90 days away: both flagged;
    - jo's expense line has an approval rule: not flagged.
- [ ] **P04-T15** A donation receipt follows its lot: the spend it paid for with tasks and evidence links, the margin earned from it, and what remains.

## Out of scope
Waiting periods, donor exits, liveness and dormancy, payments continuity (P05). Pay rules and payouts (P06). The giving UI (F07).
