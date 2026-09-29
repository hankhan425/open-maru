# L06 · Cedar compiler & decide

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L03 | L | 4 |

**Read first:** SPEC-04 §1–§3 (all), SPEC-01 §4.5–§4.6, SPEC-02 §3.4 (effective holders), §6.1 (permissions table).
**Paths:** `crates/maru_core/src/authz/{mod,compile,decide,explain}.rs`, `crates/maru_core/schema/openmaru.cedarschema`, tests, `tests/vectors/decide.json`

## Goal
Compile the IR into a Cedar policy set and answer authorization requests with Allow / Deny(reason) / RequiresApproval(rule ids). Approvals are modeled as annotated forbids so one evaluation engine covers mandates and approval gates.

## Deliverables
- Cedar schema file (entities, actions, context) and strict validation of generated policies at compile time.
- `compile(&Ir) -> Result<CompiledPolicy, CompileError>`, `cedar_text(&Ir) -> String`, `decide(&CompiledPolicy, &DecisionRequest) -> Decision` per SPEC-04 §3.
- Explanation pass producing `DenyReason`.
- All behind feature `authz`.
- `tests/vectors/decide.json`: every case below as `{ir_fixture, request, expected}` (reused by L07 and M02).

## Interfaces
```rust
pub struct DecisionRequest {
    pub principal: PrincipalRef,            // {kind: "person"|"agent", id}
    pub action: Action,
    pub resource: ResourceRef,              // {kind: "goal"|"agent"|"person", id}
    pub context: RequestContext,            // category, amount_micros, approved_rules, metric, goal, now_epoch
    pub effective_holders: BTreeMap<String, Vec<String>>,
}
```

## Tests to write first
Unless noted, IR = lumen, `now_epoch` = 2026-10-01T00:00Z, `effective_holders = {core: [mina, jo]}`.
- [ ] **L06-T01** `cedar_text(lumen)` snapshot; generated policies validate against the schema (strict mode).
- [ ] **L06-T02** Policy ids deterministic and matching SPEC-04 §2.1 naming.
- [ ] **L06-T03** builder Spend llm $10 → Allow.
- [ ] **L06-T04** builder Spend llm $30 → Deny PerRequestExceeded.
- [ ] **L06-T05** builder Spend expense $1 → Deny CategoryNotPermitted.
- [ ] **L06-T06** builder Spend llm $10 at `now_epoch` = 2027-01-01T00:00Z → Deny MandateExpired.
- [ ] **L06-T07** @jo Spend expense $100 → RequiresApproval [expense rule id].
- [ ] **L06-T08** Same with that id in `approved_rules` → Allow.
- [ ] **L06-T09** @jo Spend expense $600 → RequiresApproval with both rule ids, sorted.
- [ ] **L06-T10** @jo expense $600 with only the `> $500` rule approved → RequiresApproval [expense rule id].
- [ ] **L06-T11** @mina Spend llm $1 → Deny NoMandate (stewardship grants no spend).
- [ ] **L06-T12** @mina ReviewTask on editor → Allow; with `effective_holders = {core: [jo]}` → Deny NotSteward.
- [ ] **L06-T13** builder ClaimTask → Allow; builder CreateTask → Deny CapabilityMissing; @jo CreateTask → Allow.
- [ ] **L06-T14** builder ReportMetric `weekly_active_users` → Allow; `revenue` → Deny CapabilityMissing; @mina ReportMetric `revenue` → Allow (steward).
- [ ] **L06-T15** IssueToken: @mina on Agent builder → Allow; @jo on Agent builder → Deny NotOperator; @jo on Person jo → Allow.
- [ ] **L06-T16** StartSession on Agent builder: @mina → Allow; @jo with `context.goal = "editor"` → Allow; @jo with `context.goal = "other"` → Deny.
- [ ] **L06-T17** Custom IR with `rule spend llm > usd 100 requires approve(core, 1)` and a compute line: llm $150 → RequiresApproval; compute $150 → Allow.
- [ ] **L06-T18** Unknown principal → NoMandate; unknown goal resource → Forbidden.
- [ ] **L06-T19** Property: random requests over lumen never panic; adding the returned rule ids to `approved_rules` never yields RequiresApproval with the same ids.
- [ ] **L06-T20** Property: any Deny with PerRequestExceeded/CategoryNotPermitted/NoMandate/MandateExpired stays Deny for every `approved_rules` set (approvals can't bypass mandates).
- [ ] **L06-T21** `decide.json` vectors file matches all cases above (generated + committed; test fails on drift).
- [ ] **L06-T22** Bench (ignored by default): generated 2,000-line spec, 10k decides, p95 < 2 ms.

## Acceptance criteria
- Tests pass; no policy text built by string concatenation of unescaped user input (ids are validated identifiers; strings go through Cedar's escaping).

## Out of scope
Budgets (ledger), token verification (M01), Elixir integration (L07/M02).
