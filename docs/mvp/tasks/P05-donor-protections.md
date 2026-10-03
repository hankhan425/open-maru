# P05 · Donor protections: waiting period, exit, dormancy, continuity

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P04, C06, C07 | L | 14 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-05 §8.5, §8.7–§8.11; SPEC-02 §4.4 (scheduled versions), §5.1–§5.3; SPEC-01 §9 (`tightens`); SPEC-03 §5.4–§5.5.
**Paths:** `lib/openmaru/funding/protections/**`, `lib/openmaru/decisions/effects/amend.ex`, `lib/openmaru/payments/**`, controllers, migrations, Oban workers, `web/src/features/{goal,donate,settings}/**`

## Goal
People who receive outside money can leave, change their rules or vanish. Donors never wait on them to get their unspent money back. Rule changes give donors time to leave first, silence winds a goal down by itself, and the money keeps following people who are still there.

## Deliverables
- **Scheduled versions** (SPEC-02 §4.4, SPEC-05 §8.5). The `amend` effect schedules the version (`activates_at` = +14 days, `spec.version_scheduled`) when the org holds outside money and the diff has a change that isn't `tightens`. An Oban job activates it then, or marks it `stale` when the active version changed in the meantime.
- **Donor exit.** `POST /donations/:id/exit?t=`, only while a version is scheduled (else 409 `exit_not_open`):
  - refund the lot's remainder on its charge (`create_refund`);
  - cancel the donor's monthly series;
  - write the ledger refund transfer and `donation.exited`.
- **Liveness and dormancy** (SPEC-05 §8.7). A daily job computes steward activity for every watched goal and applies the 30/45/60/90-day steps:
  - day 45: checkout refuses with 409 `funding_tier_required`, `details.reason: "stewards_inactive"`;
  - day 60: `pause_reason: dormant`, `dormant_at` set at day 90;
  - day 90: a refund of every lot, `refund_unfunded` recorded when a refund fails.

  Steward activity resets the clock; resuming after dormancy is by a steward. Events `goal.dormancy_warning`, `goal.dormant`.
- **Public dormancy record** on the goal and org pages: date, amounts refunded and unrefunded, the steward holders' handles.
- **Payments continuity** (SPEC-05 §8.8). `stripe_accounts.connected_by_user_id` (P01). When that person is unavailable: checkout closes, monthly donations and pledge charges pause, and a replacement onboarding is allowed for any active administrator. Pledges charge on the new account; monthly donations on the old one are cancelled; the old account is kept for refunds and reconciliation (P03).
- **Closing** (SPEC-05 §8.9). C06's close effect refunds every lot before `on_close` moves the rest.
- **Pledges and forks.** `POST /pledges/:id/move?t= {goal_id}` to a goal of a fork listed on the original org (C07). It charges once the fork reaches tier 1.
- **Pledge pause and reconfirm.** Pledges paused by the ladder or by continuity resume automatically under 90 days; from 90 days they need `reconfirm` (P04).
- **Web.**
  - Goal page: a scheduled-change banner with the activation date and the exit link; liveness warnings; the dormancy record.
  - Exit page.
  - Settings: replacement Stripe account.
  - Pledge page: move to a fork.

## Tests to write first
- [ ] **P05-T01** Scheduling:
  - In an org with U > 0, a passed amendment that raises a mandate limit → scheduled 14 days out.
  - One that only adds an approval rule → activates now.
  - One that only adds a holder (`neutral`) → scheduled.
  - With U = 0 → activates now.
- [ ] **P05-T02** Activation (Clock):
  - The scheduled version activates at `activates_at`.
  - If a tightening-only amendment activated in between, it becomes `stale` and nothing is projected.
  - Spending runs under the active version throughout.
- [ ] **P05-T03** Exit:
  - During the wait, it refunds the lot's remainder (mock), cancels the monthly series, writes a refund transfer and lowers U.
  - Outside the wait → 409 `exit_not_open`. A wrong token → 404.
- [ ] **P05-T04** Ladder (Clock) on a goal with U > 0:
  - Day 29: nothing. Day 30: warning and `goal.dormancy_warning`.
  - Day 45: checkout → 409 `stewards_inactive`; monthly donations and pledge charges paused (mocks).
  - Day 60: `paused(dormant)` and spend → `goal_paused`.
  - Day 90: every lot refunded, monthly donations cancelled, pledges paused, `dormant_at` and `goal.dormant` set.
- [ ] **P05-T05** Resetting:
  - A steward signing in on day 50 resets the clock: checkout reopens, and donations and pledges resume.
  - On day 70, the goal also needs a steward to resume it.
- [ ] **P05-T06** A refund that fails (mock: insufficient balance, or charge too old) → `refund_unfunded`, shown in the public dormancy record with the amount.
- [ ] **P05-T07** After dormancy a steward resumes the goal. Pledges paused 90+ days stay paused until each donor reconfirms. Donations reopen only if tier 2 still holds.
- [ ] **P05-T08** Continuity:
  - The connector silent 45 days (or departed, or suspended) → checkout closed and charges paused.
  - Another administrator connects a replacement (mock): pledges charge on the new account, and the old account's monthly donations are cancelled.
  - A refund of an old donation still goes to the old account.
- [ ] **P05-T09** Closing a goal with U > 0 refunds every lot, then `return treasury` moves only own funds.
- [ ] **P05-T10** Moving a pledge:
  - To a goal of a fork made by a member → moved, and it charges once the fork reaches tier 1.
  - To a fork made by a non-member, or an unrelated org → 404.
- [ ] **P05-T11** Web: the scheduled-change banner and exit page; liveness warnings at 30/45/60; the dormancy record; replacement account in settings; axe reports no violations.

## Out of scope
Spec settings for these values (post-MVP; orgs may only make them stricter). Email notices (there is no mailer: warnings show on the goal, receipt and pledge pages).
