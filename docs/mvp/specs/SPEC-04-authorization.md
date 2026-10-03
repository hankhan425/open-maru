# SPEC-04 — Authorization: Cedar policies, decisions, mandate tokens

## 1. Overview

- The IR compiles to a **Cedar** policy set (ADR-5). `maru_core::decide` evaluates a request and returns `Allow`, `Deny{reason}`, or `RequiresApproval{rule_ids}`.
- Period budgets and goal funds are enforced by ledger constraints (SPEC-03), not Cedar.
- Agents (and optionally people) authenticate with **Biscuit mandate tokens** that can be attenuated offline and revoked centrally.
- `Openmaru.Mandates.authorize/3` is the single entry point every controller, the gateway, MCP, and the runtime call.

## 2. Cedar model

**Entity types:** `Person` (id = handle), `Agent` (id = agent ident), `Circle` (ident), `Goal` (ident), `Org`. `Person in [Circle]` is built from **effective holders** passed in the request. `Goal in [Org]`.

The schema is `crates/maru_core/schema/openmaru.cedarschema`; `compile` validates every generated policy set against it in strict mode. The generated policies use only the principal's circles, so a request's entity store holds just the principal (a person with its circles from `effective_holders`; an agent has none).

**Actions:** `Spend`, `ClaimTask`, `CreateTask`, `PostEvidence`, `PostGoalEvidence`, `ReportMetric`, `ReviewTask`, `CancelTask`, `PauseGoal`, `ResumeGoal`, `RequestClose`, `ManageSecrets`, `IssueToken`, `StartSession`.

**Context record:** `{ category: String, amount_micros: Long, approved_rules: Set<String>, metric: String, goal: String, now_epoch: Long }` (unused fields are sent as `""`/`0`/`[]`).

### 2.1 Generated policies (one IR → one policy set)
Policy IDs are deterministic; the snapshot test pins the full output for `lumen.maru` (`crates/maru_core/tests/snapshots/lumen.cedar`). Order: for each goal, its steward policy, its `steward-session` policies, then per mandate its `caps`, `metrics` and `spend:<cat>` policies (each only when the mandate has such lines), then its spend rules; after all goals, one `operator:` policy per agent and one `self-token:` policy per person holding a mandate, in order of first appearance. Every string from the IR is written with Cedar's string escaping, and `compile` rejects an IR whose ids, handles, metric names, rule ids, dates or amounts the language would not allow. Policies of different kinds cannot share an id: rule ids are `<goal>:r_<hex>` with no `-` in the goal id, and every other id starts with a keyword or a hyphenated prefix (OQ-13). Two rules of one goal cannot share an id either: the checker rejects such a spec (E325, OQ-15). An IR that still yields two equal ids is one the checker never emits, such as two goals with one id, and does not compile (`CompileError::DuplicatePolicyId`).

Steward powers, per goal:
```cedar
@id("steward:editor")
permit(principal in Circle::"core",
       action in [Action::"ClaimTask", Action::"CreateTask", Action::"PostEvidence", Action::"PostGoalEvidence",
                  Action::"ReportMetric", Action::"ReviewTask", Action::"CancelTask", Action::"PauseGoal",
                  Action::"ResumeGoal", Action::"RequestClose", Action::"ManageSecrets"],
       resource == Goal::"editor");
```

Mandate capabilities (capability → action: `claim_tasks`→ClaimTask, `create_tasks`→CreateTask, `post_evidence`→PostEvidence + PostGoalEvidence). Expiry becomes a `now_epoch` guard (`expires: 2027-01-01` → `1798761600`); omitted when no expiry.
```cedar
@id("mandate:editor:agent:builder:caps")
permit(principal == Agent::"builder", action in [Action::"ClaimTask", Action::"PostEvidence", Action::"PostGoalEvidence"],
       resource == Goal::"editor")
when { context.now_epoch < 1798761600 };

@id("mandate:editor:agent:builder:metrics")
permit(principal == Agent::"builder", action == Action::"ReportMetric", resource == Goal::"editor")
when { ["weekly_active_users"].contains(context.metric) && context.now_epoch < 1798761600 };
```

Spend, one policy per spend line (per-request cap folded in):
```cedar
@id("mandate:editor:agent:builder:spend:llm")
permit(principal == Agent::"builder", action == Action::"Spend", resource == Goal::"editor")
when { context.category == "llm" && context.amount_micros <= 25000000 && context.now_epoch < 1798761600 };
```

Approval rules become annotated forbids:
```cedar
@id("editor:r_1a2b3c4d") @approval("editor:r_1a2b3c4d")
forbid(principal, action == Action::"Spend", resource == Goal::"editor")
when { context.amount_micros > 500000000 }
unless { context.approved_rules.contains("editor:r_1a2b3c4d") };
```
(A category in the subject adds `context.category == "<cat>"` to `when`; no threshold omits the amount condition. `rule close` does not compile to Cedar; it only selects the close procedure.)

Tokens and sessions:
```cedar
@id("operator:builder")
permit(principal == Person::"mina", action in [Action::"IssueToken", Action::"StartSession"], resource == Agent::"builder");
@id("self-token:jo")
permit(principal == Person::"jo", action == Action::"IssueToken", resource == Person::"jo");
@id("steward-session:editor:builder")
permit(principal in Circle::"core", action == Action::"StartSession", resource == Agent::"builder")
when { context.goal == "editor" };
```
(`self-token:` policies exist for every person holding a mandate; `steward-session` for every hosted agent with a mandate in a goal. `operator:` policies exist for every agent, `byo` included; starting a session for a `byo` agent is refused later with `agent_not_hosted`, SPEC-06 §4.)

## 3. `decide` algorithm (Rust, `maru_core::authz`)

```rust
pub struct CompiledPolicy { /* PolicySet + IR index; built once per spec version */ }
pub fn compile(ir: &Ir) -> Result<CompiledPolicy, CompileError>;
pub fn cedar_text(ir: &Ir) -> String;               // for snapshots and the "Source → policy" view
pub fn decide(p: &CompiledPolicy, req: &DecisionRequest) -> Decision;

pub enum Decision { Allow, Deny { reason: DenyReason }, RequiresApproval { rule_ids: Vec<String> } }
pub enum DenyReason { NoMandate, CategoryNotPermitted, PerRequestExceeded, MandateExpired,
                      CapabilityMissing, NotSteward, NotOperator, Forbidden }
```
1. Build entities from the IR plus `req.effective_holders`; evaluate.
2. `Allow` → `Allow`.
3. `Deny` whose determining policies are all `@approval` forbids (at least one) → re-evaluate with those IDs added to `approved_rules`. If that allows → `RequiresApproval{rule_ids sorted}`; else go to 4.
4. `Deny{reason}` where reason comes from an explanation pass over the IR, first match wins. First, a resource that is not one of these → `Forbidden` (OQ-14): a goal of the spec for `Spend` and the capability actions; an agent of the spec for `StartSession`; an agent of the spec or any person for `IssueToken`. Then: (Spend) no mandate → `NoMandate`; category not in spend lines → `CategoryNotPermitted`; expired → `MandateExpired`; per-request exceeded → `PerRequestExceeded`. (Capability actions) no mandate and not a steward holder → `NotSteward`; mandate lacks capability → `CapabilityMissing`; expired → `MandateExpired`. (IssueToken/StartSession) → `NotOperator`. Otherwise `Forbidden`.

`decide` fails closed: a request Cedar cannot evaluate is `Deny{Forbidden}`. `amount_micros` above `i64::MAX` (Cedar's `Long`) is sent as `i64::MAX`, which is above every amount a spec can state. Only the policies naming the request's resource are evaluated (every generated policy has `resource == …`), which keeps `decide` independent of the spec's size.

**JSON** (NIF `decide(handle, request_json)`, vectors in `crates/maru_core/tests/vectors/decide.json` as `{name, ir_fixture, request, expected}`, with `ir_fixture` a file in `crates/maru_core/tests/fixtures/`). Every field is required and no other is accepted; actions and reasons are snake_case:
```json
{"principal": {"kind": "agent", "id": "builder"}, "action": "spend", "resource": {"kind": "goal", "id": "editor"},
 "context": {"category": "llm", "amount_micros": 10000000, "approved_rules": [], "metric": "", "goal": "", "now_epoch": 1790812800},
 "effective_holders": {"core": ["mina", "jo"]}}
```
`principal.kind` is `person` or `agent`; `resource.kind` is `goal`, `agent` or `person`; `action` is one of `spend`, `claim_task`, `create_task`, `post_evidence`, `post_goal_evidence`, `report_metric`, `review_task`, `cancel_task`, `pause_goal`, `resume_goal`, `request_close`, `manage_secrets`, `issue_token`, `start_session`. Decisions: `{"decision": "allow"}`, `{"decision": "deny", "reason": "per_request_exceeded"}`, `{"decision": "requires_approval", "rule_ids": ["editor:r_…"]}`.

Performance: `decide` p95 < 2 ms for a 2,000-line spec. The NIF exposes `compile/1` returning a resource handle cached per spec version (`:persistent_term` keyed by version id).

## 4. Mandate tokens (Biscuit)

**Format:** `om_mt_` + base64url(no padding) of the serialized Biscuit. Root key: Ed25519 from `OPENMARU_TOKEN_ROOT_KEY`; public key served at `GET /api/v1/public/token-key`.

**Authority block** (minted by the server):
```datalog
token_id("mtok_…"); mandate("mand_…"); org("org_…"); goal("goal_…");
principal("agent", "agent_…");            // or ("person", "usr_…")
check if time($t), $t < 2026-10-28T00:00:00Z;
```
Token TTL default 30 days, max 90, never beyond mandate `expires`.

**Holder attenuation** (offline, `maru token attenuate`), allowed checks:
- `check if operation($op), ["gateway"].contains($op)` — restrict to gateway / api / mcp
- `check if time($t), $t < <ts>` — shorter expiry
- `check if task("task_…")` — bind to one task (gateway requests must then send `x-openmaru-task`)
- `check if request_amount($a), $a <= <micros>` — per-request cap

**Server authorizer** supplies facts `time(now)`, `operation("api"|"gateway"|"mcp")`, `request_goal("goal_…")`, `task("task_…")` when present, `request_amount(<micros>)` for spend, and:
```datalog
check if goal($g), request_goal($g);
allow if mandate($m);
```

**Verification order:** parse → signature → revocation IDs of every block not in `revoked_token_ids` → authorizer → token row exists and not revoked → mandate `active` → mandate belongs to the token's goal and principal. Any failure → `401 invalid_token` with a `details.reason` (`malformed`, `bad_signature`, `revoked`, `expired`, `check_failed`, `mandate_revoked`).

**Storage:** `mandate_tokens(id, mandate_id, label, issued_by_user_id, expires_at, revoked_at, revocation_ids text[], last_used_at)`. The token string itself is never stored. Revoking stores the authority block's revocation ID, which also invalidates every attenuated derivative.

**Rust API** (`crates/maru_token`): `mint(root, claims) → String`, `attenuate(token, checks) → String`, `verify(root_pub, token, authorizer_facts) → Result<Claims, TokenError>`, `revocation_ids(token) → Vec<String>`.

## 5. Authorization service and spend flow (Elixir)

### 5.1 `Openmaru.Mandates.authorize(actor, action, target, context \\ %{})`
1. Load the org's active version handle (cached).
2. Goal state: `closed` → `goal_closed`; `paused` blocks `Spend`, `ClaimTask`, `StartSession` with `goal_paused`.
3. Agent actors (token): the token's mandate must be the active mandate for (goal, principal) → else `mandate_revoked`. Agent actors, and `IssueToken`/`StartSession` on an agent: the agent's operator must be an active member of the org who is neither silent nor suspended → else `operator_unavailable` (SPEC-02 §3.6). A person who departed holds no seat or mandate, so `decide` already denies them.
4. Build `effective_holders` (SPEC-02 §3.4); call `Lang.decide`.
5. Return `:allow | {:requires_approval, rule_ids} | {:deny, code}` where code is the snake_case `DenyReason`.

### 5.2 `Openmaru.Spend.request(attrs)`
Attrs: `actor, goal, category, amount_micros, source, memo, meta, task_id, session_id, receipt_upload_id, hold_timeout_secs, wait_for_approval?`.
1. `authorize(actor, :spend, goal, %{category, amount_micros})`.
2. Deny → spend record `denied` (reason in meta), emit `spend.denied`, return `{:error, code}`.
3. Allow → ledger hold (SPEC-03 §5.1) + record `held` atomically; ledger errors map to `budget_exceeded` / `goal_funds_insufficient` and a `denied` record.
4. RequiresApproval:
   - If `wait_for_approval?` is false (gateway, runtime): record `denied` with `approval_required` and the rule IDs; return `{:error, :approval_required}`.
   - Else (expense claims): place the hold (timeout 0), record `pending_approval`, open one `spend` decision per rule ID using that rule's procedure and the current spec version. When **all** pass, re-authorize with `approved_rules` under the recorded spec version and continue as Allow (expense claims post immediately). Any failure, expiry-deny, or cancellation voids the hold and marks the record `denied`.
5. `Spend.post(spend_id, actual_micros, meta)` (actual ≤ held, else `exceeds_hold`), `Spend.void(spend_id, reason)`. Both idempotent.
