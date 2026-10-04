# C07 · Leaving, silence, forks

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C04, M02, A06, F04, F05 | L | 13 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-02 §2 (`users.last_active_at`, `orgs.forked_from_*`), §3.3, §3.4 (silence), §3.5–§3.7, §4.1–§4.2; SPEC-04 §5.1 (`operator_unavailable`); SPEC-06 §4 (`stop_agent`); SPEC-09 §4 (deletion), §6.
**Paths:** `lib/openmaru/orgs/**`, `lib/openmaru/accounts/**` (activity), `lib/openmaru_web/plugs/api_auth.ex`, `lib/openmaru/mandates/**` (authorize), controllers, migrations, `web/src/features/{org,editor}/**`

## Goal
Nobody is locked into an org, and no org is locked by someone who has gone. Anyone may leave at any time, and leaving ends every power they had there. People silent for 90 days stop counting toward decisions until they come back, and agents need a reachable operator. Anyone can fork an org's spec into a new org.

## Deliverables
- **Activity.** Migration `users.last_active_at`, set at sign-up. `ApiAuth` updates it at most once an hour for requests authenticated with a web session or a PAT; mandate tokens and public requests don't count.
- **Silence and suspension** (SPEC-02 §3.4). `Orgs.effective_holders/2`, the holdover rule and every eligibility snapshot (C04) leave out silent (more than 90 days) and suspended users. One sign-in restores them.
- **Departure** (SPEC-02 §3.6). Completes C03's `leave/2`:
  - revoke the person's mandates in the org with their tokens (M01);
  - stop every agent they operate (`stop_agent`, A06);
  - refuse their ballots in open decisions (`not_eligible`).

  `Orgs.leave_all/1` for account deletion (H02-T08) runs the same steps for every org.
- **Operators** (SPEC-04 §5.1). `authorize` refuses an agent actor, and `IssueToken`/`StartSession` on an agent, with `operator_unavailable` (403) while the agent's operator has departed, is silent, suspended or deleted.
- **Forks** (SPEC-02 §3.7). Migration `orgs.forked_from_org_id` / `forked_from_version_id`. `POST /orgs/:slug/forks {slug, source}` creates the org through `create_org/3` and records the link. The original's page lists the forks made by people who were its members when they forked it. Event `org.forked`.
- **Web.**
  - Org page (F03): departed holders marked; a leave dialog that lists what ends (seats, mandates, agents stopped); a Fork action that opens the editor (F04) with the active source; the forks list; the "forked from" link.
  - Decision page (F05): the procedure as run when an amend decision shrank.

## Tests to write first
- [ ] **C07-T01** `last_active_at`: set at sign-up. A session request updates it at most once an hour (Clock), and so does a PAT. A mandate-token request and a public request don't.
- [ ] **C07-T02** Silence (Clock): a holder last active 90 days + 1 s ago is not an effective holder and is left out of a new snapshot; one sign-in makes them count again; at 89 days they count.
- [ ] **C07-T03** A suspended holder is not effective and not in snapshots while suspended; unsuspended, they count again.
- [ ] **C07-T04** Lumen with @jo silent: an amend decision for `vote(core, 2/3)` snapshots [mina] with `required_yes` 1 and passes on mina's vote. With jo active again, it needs both.
- [ ] **C07-T05** Holdover: lapsed holders who are silent are not added for an amend decision.
- [ ] **C07-T06** @mina (core holder, operator of `builder`, holder of a person mandate) leaves:
  - membership `left_at`, holder row removed, `member.left` and `holder.departed`;
  - her mandate revoked with its tokens;
  - builder stopped (tokens revoked, sessions `agent_stopped`);
  - builder's next request → 403 `operator_unavailable`, and `IssueToken` on builder by anyone → 403 `operator_unavailable`.
- [ ] **C07-T07** A departed person's ballot in a decision they were eligible for → 403 `not_eligible`.
- [ ] **C07-T08** Operator silent 91 days → builder refused `operator_unavailable` (tokens not revoked); the operator signs in → builder works again.
- [ ] **C07-T09** After leaving an `open()` org, joining again makes them a member without their seat. A new version that still lists them gives a pending holder row until they accept.
- [ ] **C07-T10** `leave_all/1` applies C07-T06's effects in every org of the user.
- [ ] **C07-T11** Fork:
  - A user forks lumen to `lumen-2` with an edited source: a new org with `forked_from_*` set, its source, no balances, no members besides the forker; E502/E504 apply to the source.
  - The original lists a fork made by a member, but not one made by a non-member.
- [ ] **C07-T12** Web: the leave dialog lists what ends; departed holders are marked; Fork opens the editor with the source and creates the org; axe reports no violations.

## Out of scope
Outside-money protections: liveness and dormancy, payments continuity when the Stripe connector is gone (P05). Pay rules skipping silent or departed payees (P06). Account deletion itself (H02).
