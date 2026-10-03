# C04 · Decisions engine & amendment proposals

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C03 | L | 8 |

**Read first:** SPEC-02 §3.4 (holdover), §4 (all), §2 (`decisions`, `decision_voters`, `ballots`, `proposals`); SPEC-01 §4.7 (member-wide votes count votes cast, OQ-16), §9; SPEC-07 §1 "Orgs, specs, decisions", `/me/inbox`.
**Paths:** `lib/openmaru/decisions/**`, `lib/openmaru/orgs/proposals.ex`, controllers, migrations

## Goal
One decision engine (approve-N / vote-threshold, deadlines, default outcomes) used for amendments now and for gated spend and goal closure later. Amendments flow through it end to end.

## Deliverables
- Migrations `decisions`, `decision_voters`, `ballots`, `proposals`.
- `Openmaru.Decisions`: `open/1`, `cast/3`, `cancel/2`, `resolve_deadline/1` (Oban worker, idempotent), `register_effect/2` (effect registry keyed by kind; each effect module implements `c:on_pass(multi, decision)` and `c:on_fail(multi, decision)`).
- Eligibility snapshot rules per SPEC-02 §4.1, stored one row per voter: holdover (amend only), requester/operator exclusion (spend only; takes `exclude_user_ids` in `open/1`), member-wide votes (members of at least 30 days), and amend decisions shrinking to the people who remain.
- Member-wide votes per SPEC-01 §4.7 and SPEC-02 §4.2–§4.3: 20% turnout, yes ≥ the threshold of votes cast, early end only when the outcome can no longer change. (C07 later leaves silent and suspended people out of every snapshot.)
- `Openmaru.Orgs.Proposals.create/2`: re-check source (Lang + E501–E504 + **E503** removing an unclosed goal), reject no-op (identical hash → 422 with `details.reason = "no_changes"`), reject stale base (409 `stale_proposal`), store diff, open an `amend` decision using the active spec's `amend` procedure and timeout.
- Built-in `amend` effect: stale check, `Orgs.activate_version/3`, mark other open amend decisions `stale`.
- Endpoints: proposals, decisions, ballots, cancel, `GET /me/inbox` (open decisions where the user is eligible and hasn't voted; pending holder acceptances).
- Events: `decision.opened`, `decision.ballot_cast`, `decision.resolved`.

## Tests to write first
- [ ] **C04-T01** `open` with `approve(core, 1)`, effective holders [mina, jo] → eligible both, `required_yes` 1, `deadline_at = now + within.secs`, deadline job enqueued at that time.
- [ ] **C04-T02** `required_yes` for votes: 2/3 of 3 → 2; 2/3 of 2 → 2; 60% of 5 → 3; 1/2 of 4 → 2 (integer arithmetic, no floats).
- [ ] **C04-T03** Eligible 0 → immediately `failed` (`no_eligible_voters`); approve 2 with 1 eligible → `failed` (`insufficient_eligible`); on_fail effect runs.
- [ ] **C04-T04** Holdover: amend decision when all core terms lapsed → lapsed holders eligible; a spend decision in the same state → `insufficient_eligible`.
- [ ] **C04-T05** Spend exclusion: requester @jo with core [mina, jo] → eligible [mina]; agent builder (operator mina) → eligible [jo].
- [ ] **C04-T06** Non-eligible ballot → 403 `not_eligible`; second ballot → 409 `already_voted`; ballot after resolution → 409 `decision_closed`.
- [ ] **C04-T07** Early pass: `approve(core, 1)` first yes → `passed`, on_pass effect runs in the same transaction.
- [ ] **C04-T08** Early fail: `vote(core, 2/3)` with 3 eligible (required 2) → two no votes → `failed`.
- [ ] **C04-T09** Deadline: default deny → `expired_failed`; default allow → `expired_passed` + effect; running the job twice is a no-op; job on an already-resolved decision is a no-op.
- [ ] **C04-T10** Cancel by author → `cancelled` + on_fail; by anyone else → 403.
- [ ] **C04-T11** Proposal with invalid source → 422 with diagnostics; with E501 → 422; decision uses active spec's `amend` procedure and timeout; diff stored.
- [ ] **C04-T12** Proposal whose `base_version` isn't active → 409 `stale_proposal`.
- [ ] **C04-T13** Proposal removing an unclosed goal → 422 with E503.
- [ ] **C04-T14** Proposal identical to active (same hash) → 422 `no_changes`.
- [ ] **C04-T15** Pass: version n+1 active with `parent_version_id` and `decision_id`; projection ran; other open amend decisions → `stale`.
- [ ] **C04-T16** Two proposals on the same base: first passes, second then passes its vote → status `stale`, no version created.
- [ ] **C04-T17** If activation fails (hook raises), the decision stays `open`, nothing is committed, error is logged.
- [ ] **C04-T18** `/me/inbox` lists eligible, un-voted, open decisions sorted by deadline plus pending holder acceptances; excludes resolved ones.
- [ ] **C04-T19** Effect registry: a dummy kind registered in test receives on_pass/on_fail exactly once.
- [ ] **C04-T20** Property (StreamData): random ballot sequences never produce both pass and fail; final status is consistent with counts and `required_yes`.
- [ ] **C04-T21** Member-wide eligibility: members who joined 29 days before opening are not eligible, at 30 days they are, members who left are not; one `decision_voters` row each, `eligible_count`, `min_turnout = ceil(eligible / 5)`.
- [ ] **C04-T22** `vote(members, 2/3)` with 100 eligible, `else deny`, at the deadline:
  - 15 yes, 0 no → below turnout → `expired_failed`;
  - 20 yes, 5 no → `passed` (20 ≥ ceil(2/3 × 25) = 17);
  - 14 yes, 11 no → `failed`.
- [ ] **C04-T23** Early end with 100 eligible and 2/3:
  - `passed` at the 67th yes; `failed` at the 34th no.
  - With 90% and `else allow`, 11 no votes and nothing else leave it open, since turnout is below 20% and the deadline would allow it.
- [ ] **C04-T24** Property (StreamData): whenever a member-wide vote ends early, every possible completion of the remaining ballots leads to the same result at the deadline.
- [ ] **C04-T25** Amend shrinking: with `amend: approve(core, 2)` and core [mina, jo] where jo's holder row was removed, the amend decision needs 1 (stored procedure `approve(core, 1)`) and passes on mina's vote. A spend decision under `approve(core, 2)` in the same state → `insufficient_eligible`.
- [ ] **C04-T26** An amend decision whose circle has no eligible holders (all of them departed) runs as `vote(members, 2/3)` with the original timeout and `else`; with no eligible members → `failed` `no_eligible_voters`.

## Out of scope
Spend effects (M02), close effects (C06), UI (F04/F05).
