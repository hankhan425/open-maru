//! The normalized intermediate representation (SPEC-01 §6), version 1.
//!
//! The IR is the only form of a spec that runtimes consume (server, web, CLI). It is
//! produced by [`check`](crate::check::check) only for sources without errors, and its
//! JSON shape is pinned by `schema/ir.v1.json`:
//!
//! - Every default is materialized; optional values with no default are `null`, never
//!   absent.
//! - Arrays keep source order.
//! - Money is integer micro-USD, at most 2^53 − 1 (E310, E318).
//! - Durations keep the unit they were written in; thresholds keep the form they were
//!   written in (`60%` is `{"num":60,"den":100,"percent":true}`, never reduced).
//! - Handles are written without `@`.

use serde::{Deserialize, Serialize};

use crate::ast;

/// The IR format version, `ir_version` in the JSON.
pub const IR_VERSION: u32 = 1;

/// A checked spec.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ir {
    /// Always [`IR_VERSION`].
    pub ir_version: u32,
    /// The spec hash (`sha256:` + hex of the canonical formatted source; SPEC-01 §1).
    pub source_hash: String,
    /// The organization.
    pub org: Org,
}

/// The org and everything in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Org {
    /// Display name.
    pub name: String,
    /// `purpose`, if given.
    pub purpose: Option<String>,
    /// How people join (default `invite(sponsors: 1)`).
    pub membership: Membership,
    /// How the spec itself changes.
    pub amend: Amend,
    /// Circles in source order.
    pub circles: Vec<Circle>,
    /// Agents in source order.
    pub agents: Vec<Agent>,
    /// Goals in source order.
    pub goals: Vec<Goal>,
}

/// `members:`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Membership {
    /// `open()`: any signed-in user may join.
    Open,
    /// `invite(sponsors: N)`.
    Invite {
        /// Distinct existing members who must sponsor a newcomer.
        sponsors: u32,
    },
}

/// `amend:` with its timeout materialized.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Amend {
    /// The decision that approves a change.
    pub procedure: Procedure,
    /// Deadline (default 7d).
    pub within: Duration,
    /// Outcome at the deadline (default `deny`); `"else"` in JSON.
    #[serde(rename = "else")]
    pub otherwise: Outcome,
}

/// A circle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Circle {
    /// Circle id.
    pub id: String,
    /// Number of seats.
    pub seats: u32,
    /// How long a holder's powers last, or `null` for no term limit.
    pub term: Option<Duration>,
    /// Declared holders' handles (without `@`), in source order.
    pub holders: Vec<String>,
}

/// An agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    /// Agent id.
    pub id: String,
    /// The accountable operator's handle (without `@`).
    pub operator: String,
    /// Where it runs (default `byo`).
    pub runtime: Runtime,
}

/// Where an agent runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Runtime {
    /// The operator's own infrastructure.
    Byo,
    /// openmaru's hosted runtime.
    Hosted,
}

/// A goal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Goal {
    /// Goal id.
    pub id: String,
    /// Title.
    pub title: String,
    /// `purpose`, if given.
    pub purpose: Option<String>,
    /// The stewarding circle's id.
    pub steward: String,
    /// Treasury funding, or `null` when funded by donations only.
    pub fund: Option<Fund>,
    /// What happens when an allocation is short (default `pause`).
    pub on_underfunded: Underfunded,
    /// Where remaining funds go on close (default `return_treasury`).
    pub on_close: OnClose,
    /// The success criterion, if any.
    pub success: Option<Success>,
    /// Mandates in source order.
    pub mandates: Vec<Mandate>,
    /// Rules in source order.
    pub rules: Vec<Rule>,
    /// Limits analysis (SPEC-01 §6.1).
    pub limits: Limits,
}

/// `fund: usd X (/ period | once) from treasury`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fund {
    /// Amount allocated each time, in micro-USD.
    pub amount_micros: u64,
    /// Each `day`/`week`/`month`, or `once`.
    pub period: FundPeriod,
}

/// When a goal's fund is allocated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FundPeriod {
    /// At each UTC day start.
    Day,
    /// At each ISO week start (Monday).
    Week,
    /// At each month start.
    Month,
    /// Once, when the goal is first adopted.
    Once,
}

/// `on_underfunded`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Underfunded {
    /// The goal pauses until topped up.
    Pause,
    /// The goal continues with what it has.
    Continue,
}

/// `on_close`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OnClose {
    /// Remaining funds return to the treasury.
    ReturnTreasury,
    /// Remaining funds move to another goal of the org.
    Transfer {
        /// The receiving goal's id.
        goal: String,
    },
}

/// `success: metric(<name>) <cmp> <value> [by <date>]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Success {
    /// Metric name.
    pub metric: String,
    /// Comparator.
    pub cmp: Cmp,
    /// Target as a decimal string (`-` sign, no `_`, no leading zeros in the integer
    /// part, fraction digits as written).
    pub value: String,
    /// Deadline `YYYY-MM-DD`, if any.
    pub by: Option<String>,
}

/// A success comparator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Cmp {
    /// `>=`.
    #[serde(rename = ">=")]
    Ge,
    /// `>`.
    #[serde(rename = ">")]
    Gt,
    /// `<=`.
    #[serde(rename = "<=")]
    Le,
    /// `<`.
    #[serde(rename = "<")]
    Lt,
    /// `==`.
    #[serde(rename = "==")]
    Eq,
}

/// A mandate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mandate {
    /// Who holds it.
    pub principal: Principal,
    /// Spend limits in source order (one per category).
    pub spend: Vec<SpendLimit>,
    /// Cap on any single spend, if any.
    pub per_request_micros: Option<u64>,
    /// Capabilities in source order without duplicates: `claim_tasks`, `create_tasks`,
    /// `post_evidence`, `report_metric:<name>`.
    pub capabilities: Vec<String>,
    /// Expiry date `YYYY-MM-DD` (invalid from 00:00Z that day), if any.
    pub expires: Option<String>,
}

/// A mandate's principal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Principal {
    /// Agent or person.
    pub kind: PrincipalKind,
    /// Agent id, or handle without `@`.
    pub id: String,
}

/// The principal kinds a mandate can name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrincipalKind {
    /// A declared agent.
    Agent,
    /// A person, by handle.
    Person,
}

/// `spend <category> <= usd X / period`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpendLimit {
    /// Category.
    pub category: Category,
    /// Cumulative limit per period, in micro-USD.
    pub limit_micros: u64,
    /// The UTC calendar period.
    pub period: Period,
}

/// A spend category.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    /// Model calls through the gateway.
    Llm,
    /// Hosted runtime sessions.
    Compute,
    /// Expense claims.
    Expense,
}

/// A UTC calendar period.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Period {
    /// A day.
    Day,
    /// An ISO week starting Monday.
    Week,
    /// A calendar month.
    Month,
}

/// An approval gate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    /// `<goal>:r_<first 8 hex of sha256(rule line)>` (SPEC-01 §4.6).
    pub id: String,
    /// What it gates.
    pub subject: Subject,
    /// The approving decision.
    pub procedure: Procedure,
    /// Deadline (default 7d).
    pub within: Duration,
    /// Outcome at the deadline (default `deny`); `"else"` in JSON.
    #[serde(rename = "else")]
    pub otherwise: Outcome,
}

/// A rule subject.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Subject {
    /// `spend [category] [> usd X]`.
    Spend {
        /// Category filter; `null` matches every category.
        category: Option<Category>,
        /// Strict lower bound in micro-USD; `null` matches every amount.
        over_micros: Option<u64>,
    },
    /// `close`.
    Close,
}

/// A decision procedure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Procedure {
    /// `approve(<circle>, N)`.
    Approve {
        /// Approving circle.
        circle: String,
        /// Distinct approvals needed.
        count: u32,
    },
    /// `vote(<circle> | members, T)`.
    Vote {
        /// Voting circle, or `null` for all members.
        circle: Option<String>,
        /// Share of yes votes needed.
        threshold: Threshold,
    },
}

/// A vote threshold as written: `a/b` or `p%` (`num = p`, `den = 100`), not reduced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Threshold {
    /// Numerator.
    pub num: u32,
    /// Denominator.
    pub den: u32,
    /// Whether it was written as a percentage.
    pub percent: bool,
}

/// A duration in the unit it was written in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Duration {
    /// Count of `unit`s.
    pub value: u64,
    /// The unit.
    pub unit: DurationUnit,
    /// Total seconds.
    pub secs: u64,
}

/// A duration unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DurationUnit {
    /// Minutes.
    #[serde(rename = "m")]
    Minutes,
    /// Hours.
    #[serde(rename = "h")]
    Hours,
    /// Days.
    #[serde(rename = "d")]
    Days,
    /// Weeks (7 days).
    #[serde(rename = "w")]
    Weeks,
    /// Years (365 days).
    #[serde(rename = "y")]
    Years,
}

/// A timeout outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// The request or change is rejected.
    Deny,
    /// The request or change goes ahead.
    Allow,
}

/// Limits analysis for a goal (SPEC-01 §6.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    /// Upper bound on spend possible in one calendar month without approvals.
    pub unapproved_monthly_max_micros: u64,
}

// ---- lowering of leaf values from the syntax tree ----

impl From<&ast::Duration> for Duration {
    fn from(d: &ast::Duration) -> Duration {
        Duration {
            value: d.value,
            unit: DurationUnit::from(d.unit),
            secs: d.secs(),
        }
    }
}

impl From<ast::DurationUnit> for DurationUnit {
    fn from(u: ast::DurationUnit) -> DurationUnit {
        match u {
            ast::DurationUnit::Minutes => DurationUnit::Minutes,
            ast::DurationUnit::Hours => DurationUnit::Hours,
            ast::DurationUnit::Days => DurationUnit::Days,
            ast::DurationUnit::Weeks => DurationUnit::Weeks,
            ast::DurationUnit::Years => DurationUnit::Years,
        }
    }
}

impl From<ast::Outcome> for Outcome {
    fn from(o: ast::Outcome) -> Outcome {
        match o {
            ast::Outcome::Deny => Outcome::Deny,
            ast::Outcome::Allow => Outcome::Allow,
        }
    }
}

impl From<ast::Runtime> for Runtime {
    fn from(r: ast::Runtime) -> Runtime {
        match r {
            ast::Runtime::Byo => Runtime::Byo,
            ast::Runtime::Hosted => Runtime::Hosted,
        }
    }
}

impl From<ast::Underfunded> for Underfunded {
    fn from(u: ast::Underfunded) -> Underfunded {
        match u {
            ast::Underfunded::Pause => Underfunded::Pause,
            ast::Underfunded::Continue => Underfunded::Continue,
        }
    }
}

impl From<ast::Category> for Category {
    fn from(c: ast::Category) -> Category {
        match c {
            ast::Category::Llm => Category::Llm,
            ast::Category::Compute => Category::Compute,
            ast::Category::Expense => Category::Expense,
        }
    }
}

impl From<ast::Period> for Period {
    fn from(p: ast::Period) -> Period {
        match p {
            ast::Period::Day => Period::Day,
            ast::Period::Week => Period::Week,
            ast::Period::Month => Period::Month,
        }
    }
}

impl From<&ast::Fund> for Fund {
    fn from(f: &ast::Fund) -> Fund {
        Fund {
            amount_micros: f.amount.micros,
            period: match f.schedule {
                ast::FundSchedule::Every(ast::Period::Day) => FundPeriod::Day,
                ast::FundSchedule::Every(ast::Period::Week) => FundPeriod::Week,
                ast::FundSchedule::Every(ast::Period::Month) => FundPeriod::Month,
                ast::FundSchedule::Once => FundPeriod::Once,
            },
        }
    }
}

impl From<&ast::SpendLimit> for SpendLimit {
    fn from(s: &ast::SpendLimit) -> SpendLimit {
        SpendLimit {
            category: Category::from(s.category),
            limit_micros: s.limit.micros,
            period: Period::from(s.period),
        }
    }
}

impl From<ast::Cmp> for Cmp {
    fn from(c: ast::Cmp) -> Cmp {
        match c {
            ast::Cmp::Ge => Cmp::Ge,
            ast::Cmp::Gt => Cmp::Gt,
            ast::Cmp::Le => Cmp::Le,
            ast::Cmp::Lt => Cmp::Lt,
            ast::Cmp::Eq => Cmp::Eq,
        }
    }
}

impl From<&ast::Success> for Success {
    fn from(s: &ast::Success) -> Success {
        let v = &s.value;
        let mut value = String::with_capacity(v.int.len() + 2);
        if v.negative {
            value.push('-');
        }
        value.push_str(&v.int);
        if let Some(frac) = &v.frac {
            value.push('.');
            value.push_str(frac);
        }
        Success {
            metric: s.metric.name.clone(),
            cmp: Cmp::from(s.cmp),
            value,
            by: s.by.as_ref().map(ast::Date::to_iso),
        }
    }
}
