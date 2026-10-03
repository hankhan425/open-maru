# P05 · Donor protections: waiting period, exit, liveness, continuity

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P04, C06, C07 | L | 14 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-05 §8.3 (closing), §8.6–§8.8, §8.11, §8.13; SPEC-02 §4.4 (scheduled versions), §5.1–§5.3; SPEC-01 §9 (`tightens`); SPEC-03 §5.4–§5.5.
**Paths:** `lib/openmaru/funding/protections/**`, `lib/openmaru/decisions/effects/amend.ex`, `lib/openmaru/payments/**`, controllers, migrations, Oban workers, `web/src/features/{goal,donate,settings}/**`

## Goal
People who receive outside money can leave, change their rules or stop working. Donors never wait on them to get their unspent money back:
- rule changes give donors time to leave first;
- a goal that stops producing accepted work stops taking money, then refunds what it holds;
- new money stops when the person who connected Stripe is gone.

## Deliverables
- **Scheduled versions** (SPEC-02 §4.4, SPEC-05 §8.6). When the org has U > 0 and the diff has a change that isn't `tightens`, the `amend` effect schedules the version: `activates_at` = +14 days, `spec.version_scheduled`. An Oban job activates it then, or marks it `stale` when the active version changed in the meantime.
- **Donor exit.** `POST /donations/:id/exit?t=` works only while a version is scheduled (else 409 `exit_not_open`). It:
  - refunds the lot's remainder, cost and unearned margin, on its charge (`create_refund`);
  - cancels the donor's monthly series;
  - writes the code-4 refund transfers from goal funds and `margin_held`, and `donation.exited`.
- **Liveness and dormancy** (SPEC-05 §8.7). A daily job computes each watched goal's last progress:
  - Day 30: checkout and pledge setup refuse with 409 `not_accepting_money`, `details.reason: "no_recent_work"`; monthly donations pause; `goal.dormancy_warning`.
  - Day 90: the goal goes dormant (`dormant_at`, `goal.dormant`):
    - monthly donations cancelled, and pledges waiting for reconfirmation;
    - if it holds unspent outside money: `paused(dormant)`, holds voided, sessions stopped, and every lot refunded on its charge, with `refund_unfunded` recorded when a refund fails.

  An accepted task resets the clock. A dormant goal refuses giving with `details.reason: "dormant"` until a steward resumes it, or, if it didn't pause, until a task is accepted on it.
- **Public dormancy record** on the goal and org pages: the date, the amounts refunded and unrefunded, and the steward holders' handles.
- **Payments continuity** (SPEC-05 §8.8). It applies when the person in `stripe_accounts.connected_by_user_id` (P01) has departed, is suspended or deleted, or is silent:
  - Giving refuses with `connector_unavailable`, and monthly donations and pledge charges pause.
  - Any active administrator may onboard a replacement account. The old row gets `replaced_at`.
  - Pledges charge on the new account, and monthly donations on the old one are cancelled.
  - Refunds go to each charge's own account. The old account stays in reconciliation (P03).
- **Closing** (SPEC-05 §8.3). C06's close effect refunds every lot, cost and margin, before `on_close` moves the rest.
- **Web.**
  - Goal page: a scheduled-change banner with the activation date and the exit link; liveness warnings; the dormancy record.
  - Exit page.
  - Settings: the replacement Stripe account.

## Tests to write first
- [ ] **P05-T01** Scheduling, in an org with U > 0, for a passed amendment that:
  - raises a mandate limit → scheduled 14 days out;
  - raises the margin, or adds a pay rule → scheduled;
  - only adds a holder (`neutral`) → scheduled;
  - only adds an approval rule → activates now.

  With U = 0, every amendment activates now, including when pledges are active.
- [ ] **P05-T02** Activation (Clock):
  - The scheduled version activates at `activates_at`.
  - If a tightening-only amendment activated in between, it becomes `stale` and nothing is projected.
  - Spending runs under the active version throughout.
- [ ] **P05-T03** Exit:
  - During the wait, a lot with margin refunds both remainders (mock), cancels the monthly series, writes refund transfers from goal funds and `margin_held`, and lowers U.
  - Outside the wait → 409 `exit_not_open`. A wrong token → 404.
- [ ] **P05-T04** Liveness (Clock), on a goal with U > 0 and a task accepted on day 0:
  - Day 29: nothing.
  - Day 30:
    - checkout and pledge setup → 409 `not_accepting_money` (`no_recent_work`);
    - monthly donations paused (mock);
    - the warning and `goal.dormancy_warning`.

  Active pledges keep their state: they charge only for accepted work.
- [ ] **P05-T05** A task accepted on day 50 resets the clock: giving reopens and monthly donations resume.
- [ ] **P05-T06** Day 90:
  - `paused(dormant)`, holds voided, and spend → `goal_paused`;
  - every lot refunded, cost and margin (mocks);
  - monthly donations cancelled, `dormant_at`, `goal.dormant`;
  - checkout → `not_accepting_money` (`dormant`).

  A refund that fails (mock: insufficient balance, or charge too old) → `refund_unfunded`, shown in the public dormancy record with the amount.
- [ ] **P05-T07** After dormancy a steward resumes the goal. Pledges charge nothing until each donor reconfirms. New donations are accepted as the cap or allowance allows.
- [ ] **P05-T08** A new goal whose first donation arrives on day 0 and that never accepts a task takes no new money from day 30.
- [ ] **P05-T09** Continuity:
  - The connector silent 90 days, departed or suspended → giving refuses with `connector_unavailable`, and charges pause.
  - Another administrator connects a replacement (mock): pledges charge on the new account, and the old account's monthly donations are cancelled.
  - A refund of an old donation still goes to the old account.
- [ ] **P05-T10** Closing a goal with U > 0 refunds every lot (cost and margin), then `return treasury` moves only own and earned money.
- [ ] **P05-T11** Web:
  - the scheduled-change banner and exit page;
  - the liveness warning at 30 days and the dormancy record;
  - the replacement account in settings;
  - axe reports no violations.
- [ ] **P05-T12** A goal watched only for a pledge (U = 0) reaches day 90: it is marked dormant without pausing, its own-funded spend still works, and giving refuses with `dormant`. A task accepted on day 100 ends dormancy and reopens giving; the pledge still needs reconfirmation.

## Out of scope
Spec settings for these values (post-MVP; orgs may only make them stricter). Email notices (there is no mailer: warnings show on the goal, receipt and pledge pages).
