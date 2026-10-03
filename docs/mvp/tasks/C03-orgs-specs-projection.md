# C03 · Orgs, spec versions, projection, membership

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C01, G01, L07 | L | 7 |

**Read first:** SPEC-02 §1–§3 (all), §7; SPEC-03 §3 (org accounts); SPEC-07 §1 "Orgs, specs, decisions" and `/public/world`; SPEC-09 §6 (holder consent, suspension).
**Paths:** `lib/openmaru/orgs/**`, controllers, migrations

## Goal
Orgs exist as versioned, content-addressed specs. Activating a version projects its IR into relational tables that everything else queries. Membership and holder consent work.

## Deliverables
- Migrations: `orgs`, `memberships`, `sponsorships`, `spec_versions`, `circles`, `circle_holders`, `agents`, `goals`, `mandates` (status and terms only; tokens in M01).
- `Openmaru.Orgs`: `check_source/2` (Lang check + server validation E501/E502/E504), `create_org/3`, `activate_version/3` (used by C04), `active_version/1`, `effective_holders/2`, `administrators/1` (SPEC-05 §2; P01 and G02 use it), `accept_holder/2`, `decline_holder/2`, `join/2`, `sponsor/3`, `leave/2` (membership and seats; C07 adds the rest of SPEC-02 §3.6), `world/0`.
- **Projection** per SPEC-02 §3.3 returning a change summary `%{goals_adopted, goals_removed, mandates_created, mandates_changed (with before/after terms), mandates_revoked, agents_removed, holders_added, holders_removed}`.
- **Projection hooks**: `config :openmaru, :projection_hooks, [Module…]`; each `c:run(multi, org, version, summary) :: Ecto.Multi.t()` executes inside the activation transaction. Ship an empty default list.
- Org ledger accounts created at org creation via `Openmaru.Ledger` (codes 100, 101, 110, 200, 210×2).
- Daily Oban job emitting `holder.lapsed` for terms ending that day.
- Endpoints per SPEC-07 (owner C03), including `POST /specs/check` and `GET /public/world` (shared-member edge weight = count of shared active members).

## Tests to write first
- [ ] **C03-T01** `POST /specs/check` returns diagnostics, IR, charter for valid source; invalid source → 200 with diagnostics and `ir: null`.
- [ ] **C03-T02** Create org from lumen by @mina (users mina, jo exist) → org, version 1 active with hash/IR/charter; circles, agents, goals, mandates projected; memberships for mina (creator), jo (holder); events `org.created`, `spec.version_activated`, `goal.adopted`.
- [ ] **C03-T03** Unknown handle → 422 `validation_failed` with E501 on that handle's span.
- [ ] **C03-T04** Creator not a holder of any circle → 422 E502.
- [ ] **C03-T05** Genesis with `amend: approve(core, 2)` and holders mina, jo → 422 E504 (only creator accepted).
- [ ] **C03-T06** Slug rules (`[a-z0-9-]{3,40}`) and uniqueness (409 `slug_taken`).
- [ ] **C03-T07** Holder consent: @jo not effective until accept; accept → effective + `holder.accepted`; decline → `holder.declined`, still listed as pending.
- [ ] **C03-T08** Terms (Clock): appointed 2026-01-01 with `term: 1y` → effective on 2026-12-31, not on 2027-01-02; lapse job emits `holder.lapsed` once.
- [ ] **C03-T09** Projection on a new version: continuing holder keeps `appointed_at`; newly listed holder gets activation time; lapsed-and-still-listed holder resets `appointed_at`; unlisted holder gets `removed_at`; a holder who left but is still listed gets a new pending row.
- [ ] **C03-T10** Projection: changed mandate keeps its id with new `terms`; removed mandate → `revoked`; removed agent → `active=false`.
- [ ] **C03-T11** Change summary contents for a version that adds a goal, changes a mandate, and revokes another.
- [ ] **C03-T12** Hooks run inside the transaction: a test hook records calls; a failing hook rolls back the whole activation (no version, no events).
- [ ] **C03-T13** Org creation creates the six org ledger accounts with the right codes and flags.
- [ ] **C03-T14** `GET /orgs/:slug` returns circles with effective and pending holders, goals summary, member count; `GET /orgs/:slug/spec` and `/spec/versions[/:n]`; unknown → 404.
- [ ] **C03-T15** `open()` join → `member.joined`; joining twice is idempotent.
- [ ] **C03-T16** `invite(sponsors: 2)`: one sponsor → not a member; second distinct sponsor → member; self-sponsor → 403; non-member sponsor → 403.
- [ ] **C03-T17** Leave: anyone may leave, listed holders and operators included (OQ-16). Membership gets `left_at`, the person's holder rows get `removed_at` so they stop being effective holders, and `member.left` / `holder.departed` are emitted. Mandates, tokens and agents follow in C07.
- [ ] **C03-T18** `GET /public/world`: two orgs sharing two members → one edge with weight 2; goal summaries included.
- [ ] **C03-T19** Suspended org shows `status: suspended`; suspended user cannot create orgs (403).
- [ ] **C03-T21** `administrators/1`: effective holders of the `amend` circle; with `amend: vote(members, …)`, every effective holder of any circle.
- [ ] **C03-T20** Architecture test: only `Openmaru.Lang` references `Openmaru.Lang.Native` (xref).

## Out of scope
Amendment proposals and decisions (C04), goal funding (G02), mandate tokens (M01).
