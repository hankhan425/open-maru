//! Authorization (SPEC-04 §2–§3): the IR compiled to a Cedar policy set, and `decide`.
//!
//! [`compile`] turns an [`Ir`](crate::Ir) into a [`CompiledPolicy`]: one Cedar policy per
//! steward power, mandate capability, spend line, approval rule, operator, self-issued
//! token and steward session, validated in strict mode against
//! `schema/openmaru.cedarschema` ([`CEDAR_SCHEMA`]). [`decide`] answers a
//! [`DecisionRequest`] with [`Decision::Allow`], [`Decision::Deny`] and a [`DenyReason`],
//! or [`Decision::RequiresApproval`] with the ids of the approval rules that gate it.
//! Approval rules are forbids annotated `@approval`, so one Cedar evaluation covers
//! mandates and approval gates.
//!
//! Period budgets and goal funds are not here: the ledger enforces them (SPEC-03).

mod compile;
mod decide;
mod explain;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub use crate::ir::PrincipalKind;
pub use compile::{CompileError, CompiledPolicy, cedar_text, compile};
pub use decide::decide;

/// The Cedar schema every generated policy set validates against
/// (`schema/openmaru.cedarschema`).
pub const CEDAR_SCHEMA: &str = include_str!("../../schema/openmaru.cedarschema");

/// An action a principal asks to take (SPEC-04 §2). JSON uses the snake_case name
/// (`"spend"`, `"claim_task"`); Cedar uses [`Action::cedar_name`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Spend from a goal (gateway calls, compute, expense claims).
    Spend,
    /// Claim a task (and heartbeat, release, submit it).
    ClaimTask,
    /// Create a task.
    CreateTask,
    /// Post evidence on a task.
    PostEvidence,
    /// Post goal-level evidence (no task).
    PostGoalEvidence,
    /// Report a value of the metric in [`RequestContext::metric`].
    ReportMetric,
    /// Accept or reject a submitted task.
    ReviewTask,
    /// Cancel a task.
    CancelTask,
    /// Pause a goal.
    PauseGoal,
    /// Resume a paused goal.
    ResumeGoal,
    /// Ask to close a goal.
    RequestClose,
    /// Manage a goal's secrets.
    ManageSecrets,
    /// Issue a mandate token for an agent or for oneself.
    IssueToken,
    /// Start a hosted-runtime session for an agent, for the goal in
    /// [`RequestContext::goal`].
    StartSession,
}

impl Action {
    /// Every action, in the order of SPEC-04 §2.
    pub const ALL: [Action; 14] = [
        Action::Spend,
        Action::ClaimTask,
        Action::CreateTask,
        Action::PostEvidence,
        Action::PostGoalEvidence,
        Action::ReportMetric,
        Action::ReviewTask,
        Action::CancelTask,
        Action::PauseGoal,
        Action::ResumeGoal,
        Action::RequestClose,
        Action::ManageSecrets,
        Action::IssueToken,
        Action::StartSession,
    ];

    /// The Cedar action id (`Action::"<name>"`).
    pub const fn cedar_name(self) -> &'static str {
        match self {
            Action::Spend => "Spend",
            Action::ClaimTask => "ClaimTask",
            Action::CreateTask => "CreateTask",
            Action::PostEvidence => "PostEvidence",
            Action::PostGoalEvidence => "PostGoalEvidence",
            Action::ReportMetric => "ReportMetric",
            Action::ReviewTask => "ReviewTask",
            Action::CancelTask => "CancelTask",
            Action::PauseGoal => "PauseGoal",
            Action::ResumeGoal => "ResumeGoal",
            Action::RequestClose => "RequestClose",
            Action::ManageSecrets => "ManageSecrets",
            Action::IssueToken => "IssueToken",
            Action::StartSession => "StartSession",
        }
    }
}

/// Who asks: a person (by handle, without `@`) or an agent (by id).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrincipalRef {
    /// `"person"` or `"agent"`.
    pub kind: PrincipalKind,
    /// The handle or agent id.
    pub id: String,
}

/// The kinds of resource an action applies to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    /// A goal, by id.
    Goal,
    /// An agent, by id.
    Agent,
    /// A person, by handle.
    Person,
}

/// What the action applies to.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceRef {
    /// `"goal"`, `"agent"` or `"person"`.
    pub kind: ResourceKind,
    /// The goal id, agent id or handle.
    pub id: String,
}

/// The Cedar `context` record (SPEC-04 §2). Every field is always sent; unused ones are
/// `""`, `0` or `[]`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestContext {
    /// Spend category (`"llm"`, `"compute"`, `"expense"`).
    pub category: String,
    /// Spend amount in micro-USD. Amounts above `i64::MAX` are treated as `i64::MAX`,
    /// which is still above every limit a spec can state.
    pub amount_micros: u64,
    /// Ids of the approval rules whose decisions have passed for this request.
    pub approved_rules: Vec<String>,
    /// Metric name, for `report_metric`.
    pub metric: String,
    /// Goal id, for `start_session`.
    pub goal: String,
    /// The request time in seconds since the Unix epoch (UTC).
    pub now_epoch: i64,
}

/// An authorization request (L06 interface).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionRequest {
    /// Who asks.
    pub principal: PrincipalRef,
    /// What they ask to do.
    pub action: Action,
    /// What it applies to.
    pub resource: ResourceRef,
    /// The context record.
    pub context: RequestContext,
    /// Effective holders (SPEC-02 §3.4) by circle id: handles without `@`.
    pub effective_holders: BTreeMap<String, Vec<String>>,
}

/// The answer to a [`DecisionRequest`]. JSON: `{"decision":"allow"}`,
/// `{"decision":"deny","reason":"no_mandate"}`,
/// `{"decision":"requires_approval","rule_ids":["editor:r_…"]}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case", deny_unknown_fields)]
pub enum Decision {
    /// The action may go ahead.
    Allow,
    /// The action is refused.
    Deny {
        /// Why.
        reason: DenyReason,
    },
    /// The action may go ahead once every listed approval rule's decision passes.
    RequiresApproval {
        /// Approval rule ids, sorted.
        rule_ids: Vec<String>,
    },
}

/// Why a request is denied (SPEC-04 §3, step 4). JSON and Elixir use the snake_case name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DenyReason {
    /// The principal holds no mandate in the goal.
    NoMandate,
    /// The mandate has no spend line for the category.
    CategoryNotPermitted,
    /// The amount is over the mandate's `per_request` cap.
    PerRequestExceeded,
    /// The mandate has expired.
    MandateExpired,
    /// The mandate does not grant the capability.
    CapabilityMissing,
    /// The principal has no mandate in the goal and is not an effective holder of its
    /// steward circle.
    NotSteward,
    /// The principal does not operate the agent (or, for a person resource, is not that
    /// person holding a mandate; for sessions, not a steward of the goal).
    NotOperator,
    /// Anything else, such as an unknown goal or agent.
    Forbidden,
}
