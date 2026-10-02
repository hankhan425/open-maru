# C07 · Ownership, leaving, succession, forks

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C04, M02, A06, F04, F05 | L | 13 |

**Before you start:** OQ-16 is open. Confirm its proposals with the user, write the decisions into SPEC-02 (§2, §3.4, §3.5, §4), SPEC-05 §2, SPEC-07 (§1 rows, §2 codes), SPEC-08 §3 and SPEC-09 §4, and mark OQ-16 resolved. Do this in the first commit, before the failing tests. The design below is the proposal; where the user changes it, change this file too.
**Read first:** OPEN_QUESTIONS OQ-7, OQ-16; PRD §5, §6; SPEC-02 §3 (all), §4; SPEC-04 §5.1; SPEC-05 §2 (administrators); SPEC-06 §4 (`stop_agent`); SPEC-09 §4.
**Paths:** `lib/openmaru/orgs/**`, `lib/openmaru/decisions/**`, `lib/openmaru/mandates/**` (authorize), controllers, migrations, `web/src/features/{org,decisions,editor}/**`

## Goal
Nobody is locked into an org, and no org is locked by someone who has gone. Anyone except the owner may leave at any time; the owner hands ownership on first. When someone leaves or goes inactive, the owner or the administrators appoint a successor to their roles. If the owner goes inactive, members can fork the org.

## Design (proposed in OQ-16)
- **Owner.** Each org has one owner: a platform role outside the spec, initially the creator (`orgs.owner_user_id`), always an active member. The owner can transfer ownership and decide successions, and governs nothing else. The org page names the owner.
- **Transferring ownership.** The owner offers ownership to an active member, who accepts or declines from their inbox (consent, as for holders). Audited.
- **Leaving.** Anyone except the owner may leave at any time; the owner gets 409 `ownership_transfer_required`. Leaving ends all of these at once:
  - **Membership.**
  - **Seats.** Holder rows get `removed_at`, so the person no longer counts in any new decision and can't vote in open ones.
  - **Operator roles.** Each agent they operate is stopped as by `stop_agent` and refused until a successor is named.
  - **Mandates.** They are revoked, with their tokens.

  The spec still names the person until a succession or an amendment changes it, and the org page marks them as left. If a later version still names them, they get the roles back only the usual way: a seat must be accepted again.
- **Account deletion** (H02) is refused while the user owns an org; otherwise the user leaves every org first.
- **Inactive.** A member with no authenticated activity (sign-in, API or token use, ballot) for 90 days (`users.last_active_at`, updated at most hourly). A succession for an inactive member notifies them in the inbox; their objection within 7 days cancels it.
- **Succession.** A decision of kind `succession` names a person who left or is inactive and one successor, who must be an active member.
  - **Who decides.** It passes when the owner approves, or when a majority of the remaining administrators approve (SPEC-05 §2, not counting the person replaced), within 7 days; otherwise it is denied.
  - **Effect.** A new spec version that replaces the person's handle with the successor's in every holder list, operator and mandate, and changes nothing else.
  - **Checks.** The new version is checked like a proposal. If the successor already holds that seat or mandate (E323/E312), the succession is refused.
  - **Afterwards.** The successor still accepts seats (SPEC-02 §3.2). Version history and activity show "Succession: @old → @new".
  - **Why it's an exception.** This is the one change to a spec that does not go through `amend` (SPEC-01 §4.1). It is limited to people who left or are inactive, and the org page states the rule.
- **Fork.** A member forks an org into a new one, which the forker creates and owns. The new org's source starts as the active spec's source, through the normal creation path: E501/E502/E504 apply, so the web opens the source in the editor first (F04). Only the spec is copied: no funds, members, Stripe account or history (cross-org flows stay out of scope). Both orgs link to each other (`forked_from_org_id`, `forked_from_version_id`).

## Deliverables
- Migrations: `orgs.owner_user_id` (backfilled from `created_by`), `ownership_offers`, `orgs.forked_from_org_id` / `forked_from_version_id`, `users.last_active_at`, `decisions.kind` gains `succession`.
- `Openmaru.Orgs`: `offer_ownership/3`, `accept_ownership/2`, `decline_ownership/2`, `leave/2` (new rules), `inactive?/2`, `fork/3`.
- Decisions: the `succession` kind, its eligibility (owner or remaining administrators) and its effect (a version activated through `Orgs.activate_version/3`), registered like C04's effects.
- `Openmaru.Mandates.authorize` (M02): a person who left the org has no powers in it; an agent whose operator left is refused with `operator_departed` (403).
- Endpoints (SPEC-07): `POST /orgs/:slug/ownership {handle}`, `POST /orgs/:slug/ownership/accept`, `POST /orgs/:slug/ownership/decline`, `POST /orgs/:slug/successions {person, successor}`, `POST /orgs/:slug/successions/:id/object`, `POST /orgs/:slug/forks {slug, source}`. New codes: `ownership_transfer_required` (409), `operator_departed` (403), `not_inactive` (409).
- Events: `member.left`, `holder.departed`, `org.ownership_offered`, `org.ownership_transferred`, `succession.objected`, `org.forked`. Audit rows for ownership changes.
- Web: owner and "left" markers on the org page (F03); actions to leave (listing what ends), transfer or accept ownership, start a succession and fork; succession decisions in the inbox and decision page (F05) showing the swap.

## Tests to write first
- [ ] **C07-T01** Creating an org makes the creator its owner; `GET /orgs/:slug` shows `owner`.
- [ ] **C07-T02** Ownership: the owner offers it to an active member, who accepts → new owner and an audit row; a decline leaves it unchanged; an offer by a non-owner → 403; an offer to a non-member → 422.
- [ ] **C07-T03** The owner leaving, or deleting their account, → 409 `ownership_transfer_required`; after a transfer, leaving works.
- [ ] **C07-T04** In lumen, @jo leaves: membership ended, jo's `core` holder row removed, `effective_holders(core) == [mina]`, events `member.left` and `holder.departed`; the org page lists jo as left.
- [ ] **C07-T05** After jo leaves, an amend decision for `vote(core, 2/3)` snapshots [mina] with `required_yes` 1 and passes on mina's vote; a spend decision under `approve(core, 2)` fails `insufficient_eligible`.
- [ ] **C07-T06** jo was eligible in an open decision; jo's ballot after leaving → 403 `not_eligible`.
- [ ] **C07-T07** @mina (operator of `builder`) transfers ownership and leaves: builder's tokens are revoked and its sessions stopped; its next request → 403 `operator_departed`; nobody can issue it a token until a succession names an operator.
- [ ] **C07-T08** A person with a mandate leaves: their mandate is revoked with its tokens; rejoining an `open()` org makes them a member again but restores neither seat nor mandate.
- [ ] **C07-T09** Inactivity (Clock): last active 89 days ago → not inactive, and a succession for them → 409 `not_inactive`; 90 days → inactive.
- [ ] **C07-T10** The owner starts a succession for jo (left) with successor @sam and approves it: the new version replaces `@jo` with `@sam` in `core` and in jo's mandate, and its diff has only those changes; sam is a pending holder until accepting.
- [ ] **C07-T11** Without the owner, a majority of the remaining administrators passes a succession and a minority does not; the person replaced is not eligible.
- [ ] **C07-T12** A succession for an inactive member notifies them; their objection within 7 days cancels it; with no objection it can pass after 7 days.
- [ ] **C07-T13** A succession is refused when the successor already holds the seat or mandate (E323/E312 in `details.diagnostics`) or is not an active member (422).
- [ ] **C07-T14** A member forks lumen to `lumen-2`: a new org with the forker as creator and owner, its source the submitted source, no ledger balances and no members besides the forker; both org pages link to each other; a non-member → 403.
- [ ] **C07-T15** Web: leave (listing what ends), transfer and accept ownership, start a succession and fork; "left" markers and the owner on the org page; succession decisions in the inbox; axe reports no violations.

## Out of scope
Forks that carry funds, members or history, and any other cross-org flow (PRD §6). Account deletion itself (H02). Email notices (there is no mailer).
