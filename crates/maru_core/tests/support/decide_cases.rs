//! The L06 decision cases (L06-T03..T18), shared by the tests that assert them and by
//! `tests/vectors/decide.json` (L06-T21), which serializes them for L07 and M02.
//!
//! Unless a case says otherwise: IR = lumen, `now_epoch` = 2026-10-01T00:00Z,
//! `effective_holders = {core: [mina, jo]}`, and unused context fields are `""`, `0`
//! or `[]`.

use std::collections::BTreeMap;

use maru_core::Ir;
use maru_core::authz::{
    Action, Decision, DecisionRequest, DenyReason, PrincipalKind, PrincipalRef, RequestContext,
    ResourceKind, ResourceRef,
};
use serde::Serialize;

use super::checking::ir_ok;

/// 2026-10-01T00:00:00Z.
pub const NOW: i64 = 1_790_812_800;
/// 2027-01-01T00:00:00Z: builder's mandate expires then.
pub const JAN_2027: i64 = 1_798_761_600;

/// The fixtures the cases use, by file name in `tests/fixtures/`.
pub const FIXTURES: &[(&str, &str)] = &[
    ("lumen.maru", include_str!("../fixtures/lumen.maru")),
    ("llm_gate.maru", include_str!("../fixtures/llm_gate.maru")),
];

/// The source of fixture `name`.
pub fn fixture_source(name: &str) -> &'static str {
    FIXTURES
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, src)| *src)
        .unwrap_or_else(|| panic!("no fixture {name}"))
}

/// The IR of fixture `name` (which must check without diagnostics).
pub fn fixture_ir(name: &str) -> Ir {
    ir_ok(fixture_source(name))
}

/// One vector: `{name, ir_fixture, request, expected}`.
#[derive(Debug, Clone, Serialize)]
pub struct Case {
    /// The test id and what the case shows.
    pub name: String,
    /// File name in `crates/maru_core/tests/fixtures/`.
    pub ir_fixture: &'static str,
    pub request: DecisionRequest,
    pub expected: Decision,
}

/// `n` dollars in micro-USD.
pub const fn usd(n: u64) -> u64 {
    n * 1_000_000
}

pub fn agent(id: &str) -> PrincipalRef {
    PrincipalRef {
        kind: PrincipalKind::Agent,
        id: id.to_string(),
    }
}

pub fn person(handle: &str) -> PrincipalRef {
    PrincipalRef {
        kind: PrincipalKind::Person,
        id: handle.to_string(),
    }
}

pub fn goal(id: &str) -> ResourceRef {
    ResourceRef {
        kind: ResourceKind::Goal,
        id: id.to_string(),
    }
}

pub fn agent_resource(id: &str) -> ResourceRef {
    ResourceRef {
        kind: ResourceKind::Agent,
        id: id.to_string(),
    }
}

pub fn person_resource(handle: &str) -> ResourceRef {
    ResourceRef {
        kind: ResourceKind::Person,
        id: handle.to_string(),
    }
}

/// `{circle: [handles]}`.
pub fn holders(entries: &[(&str, &[&str])]) -> BTreeMap<String, Vec<String>> {
    entries
        .iter()
        .map(|(c, hs)| (c.to_string(), hs.iter().map(|h| h.to_string()).collect()))
        .collect()
}

/// A request with the defaults above.
pub fn req(principal: PrincipalRef, action: Action, resource: ResourceRef) -> DecisionRequest {
    DecisionRequest {
        principal,
        action,
        resource,
        context: RequestContext {
            now_epoch: NOW,
            ..RequestContext::default()
        },
        effective_holders: holders(&[("core", &["mina", "jo"])]),
    }
}

/// `principal` spends `amount_micros` on `category` from goal `editor`.
pub fn spend(principal: PrincipalRef, category: &str, amount_micros: u64) -> DecisionRequest {
    req(principal, Action::Spend, goal("editor")).category(category, amount_micros)
}

/// Builder-style edits of a request.
pub trait RequestExt: Sized {
    fn category(self, category: &str, amount_micros: u64) -> Self;
    fn at(self, now_epoch: i64) -> Self;
    fn approved(self, rule_ids: &[&str]) -> Self;
    fn metric(self, metric: &str) -> Self;
    fn for_goal(self, goal: &str) -> Self;
    fn holders(self, holders: BTreeMap<String, Vec<String>>) -> Self;
}

impl RequestExt for DecisionRequest {
    fn category(mut self, category: &str, amount_micros: u64) -> Self {
        self.context.category = category.to_string();
        self.context.amount_micros = amount_micros;
        self
    }

    fn at(mut self, now_epoch: i64) -> Self {
        self.context.now_epoch = now_epoch;
        self
    }

    fn approved(mut self, rule_ids: &[&str]) -> Self {
        self.context.approved_rules = rule_ids.iter().map(|r| r.to_string()).collect();
        self
    }

    fn metric(mut self, metric: &str) -> Self {
        self.context.metric = metric.to_string();
        self
    }

    fn for_goal(mut self, goal: &str) -> Self {
        self.context.goal = goal.to_string();
        self
    }

    fn holders(mut self, holders: BTreeMap<String, Vec<String>>) -> Self {
        self.effective_holders = holders;
        self
    }
}

pub fn allow() -> Decision {
    Decision::Allow
}

pub fn deny(reason: DenyReason) -> Decision {
    Decision::Deny { reason }
}

pub fn requires(rule_ids: &[&str]) -> Decision {
    Decision::RequiresApproval {
        rule_ids: rule_ids.iter().map(|r| r.to_string()).collect(),
    }
}

/// Lumen's rule ids: `rule spend > usd 500 …` and `rule spend expense …`.
pub struct LumenRules {
    pub over_500: String,
    pub expense: String,
}

pub fn lumen_rules() -> LumenRules {
    let ir = fixture_ir("lumen.maru");
    let rules = &ir.org.goals[0].rules;
    LumenRules {
        over_500: rules[0].id.clone(),
        expense: rules[1].id.clone(),
    }
}

/// The id of `llm_gate.maru`'s only rule.
pub fn llm_gate_rule() -> String {
    fixture_ir("llm_gate.maru").org.goals[0].rules[0].id.clone()
}

fn case(name: &str, request: DecisionRequest, expected: Decision) -> Case {
    case_in("lumen.maru", name, request, expected)
}

fn case_in(
    ir_fixture: &'static str,
    name: &str,
    request: DecisionRequest,
    expected: Decision,
) -> Case {
    Case {
        name: name.to_string(),
        ir_fixture,
        request,
        expected,
    }
}

/// Every case of L06-T03..T18, in order.
pub fn cases() -> Vec<Case> {
    use DenyReason::*;
    let LumenRules { over_500, expense } = lumen_rules();
    let mut sorted = [over_500.clone(), expense.clone()];
    sorted.sort();
    let both: Vec<&str> = sorted.iter().map(String::as_str).collect();
    let gate = llm_gate_rule();
    vec![
        case(
            "L06-T03 builder spends $10 on llm",
            spend(agent("builder"), "llm", usd(10)),
            allow(),
        ),
        case(
            "L06-T04 builder spends $30 on llm, over its $25 per-request cap",
            spend(agent("builder"), "llm", usd(30)),
            deny(PerRequestExceeded),
        ),
        case(
            "L06-T05 builder spends $1 on expense, which it has no line for",
            spend(agent("builder"), "expense", usd(1)),
            deny(CategoryNotPermitted),
        ),
        case(
            "L06-T06 builder spends $10 on llm on 2027-01-01, when its mandate expires",
            spend(agent("builder"), "llm", usd(10)).at(JAN_2027),
            deny(MandateExpired),
        ),
        case(
            "L06-T07 @jo claims a $100 expense",
            spend(person("jo"), "expense", usd(100)),
            requires(&[&expense]),
        ),
        case(
            "L06-T08 @jo claims a $100 expense with the expense rule approved",
            spend(person("jo"), "expense", usd(100)).approved(&[&expense]),
            allow(),
        ),
        case(
            "L06-T09 @jo claims a $600 expense",
            spend(person("jo"), "expense", usd(600)),
            requires(&both),
        ),
        case(
            "L06-T10 @jo claims a $600 expense with only the > $500 rule approved",
            spend(person("jo"), "expense", usd(600)).approved(&[&over_500]),
            requires(&[&expense]),
        ),
        case(
            "L06-T11 @mina spends $1 on llm: stewardship grants no spend",
            spend(person("mina"), "llm", usd(1)),
            deny(NoMandate),
        ),
        case(
            "L06-T12 @mina reviews a task on editor as a steward",
            req(person("mina"), Action::ReviewTask, goal("editor")),
            allow(),
        ),
        case(
            "L06-T12 @mina reviews a task on editor when only @jo is an effective holder",
            req(person("mina"), Action::ReviewTask, goal("editor"))
                .holders(holders(&[("core", &["jo"])])),
            deny(NotSteward),
        ),
        case(
            "L06-T13 builder claims a task",
            req(agent("builder"), Action::ClaimTask, goal("editor")),
            allow(),
        ),
        case(
            "L06-T13 builder creates a task without create_tasks",
            req(agent("builder"), Action::CreateTask, goal("editor")),
            deny(CapabilityMissing),
        ),
        case(
            "L06-T13 @jo creates a task",
            req(person("jo"), Action::CreateTask, goal("editor")),
            allow(),
        ),
        case(
            "L06-T14 builder reports weekly_active_users",
            req(agent("builder"), Action::ReportMetric, goal("editor"))
                .metric("weekly_active_users"),
            allow(),
        ),
        case(
            "L06-T14 builder reports revenue, which its mandate does not name",
            req(agent("builder"), Action::ReportMetric, goal("editor")).metric("revenue"),
            deny(CapabilityMissing),
        ),
        case(
            "L06-T14 @mina reports revenue as a steward",
            req(person("mina"), Action::ReportMetric, goal("editor")).metric("revenue"),
            allow(),
        ),
        case(
            "L06-T15 @mina issues a token for builder as its operator",
            req(
                person("mina"),
                Action::IssueToken,
                agent_resource("builder"),
            ),
            allow(),
        ),
        case(
            "L06-T15 @jo issues a token for builder",
            req(person("jo"), Action::IssueToken, agent_resource("builder")),
            deny(NotOperator),
        ),
        case(
            "L06-T15 @jo issues a token for @jo, who holds a mandate",
            req(person("jo"), Action::IssueToken, person_resource("jo")),
            allow(),
        ),
        case(
            "L06-T16 @mina starts a session for builder as its operator",
            req(
                person("mina"),
                Action::StartSession,
                agent_resource("builder"),
            ),
            allow(),
        ),
        case(
            "L06-T16 @jo starts a session for builder on editor as a steward",
            req(
                person("jo"),
                Action::StartSession,
                agent_resource("builder"),
            )
            .for_goal("editor"),
            allow(),
        ),
        case(
            "L06-T16 @jo starts a session for builder on a goal builder has no mandate in",
            req(
                person("jo"),
                Action::StartSession,
                agent_resource("builder"),
            )
            .for_goal("other"),
            deny(NotOperator),
        ),
        case_in(
            "llm_gate.maru",
            "L06-T17 builder spends $150 on llm, over the llm rule's $100",
            spend(agent("builder"), "llm", usd(150)),
            requires(&[&gate]),
        ),
        case_in(
            "llm_gate.maru",
            "L06-T17 builder spends $150 on compute, which the llm rule does not cover",
            spend(agent("builder"), "compute", usd(150)),
            allow(),
        ),
        case(
            "L06-T18 an unknown agent spends $10 on llm",
            spend(agent("ghost"), "llm", usd(10)),
            deny(NoMandate),
        ),
        case(
            "L06-T18 builder spends $10 on llm from an unknown goal",
            req(agent("builder"), Action::Spend, goal("nope")).category("llm", usd(10)),
            deny(Forbidden),
        ),
    ]
}

/// The cases whose name starts with `id` (e.g. `"L06-T12"`).
pub fn cases_for(id: &str) -> Vec<Case> {
    let prefix = format!("{id} ");
    let found: Vec<Case> = cases()
        .into_iter()
        .filter(|c| c.name.starts_with(&prefix))
        .collect();
    assert!(!found.is_empty(), "no cases for {id}");
    found
}
