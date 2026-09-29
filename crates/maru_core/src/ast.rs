//! Typed syntax tree for maru-lang v0, mirroring the grammar in SPEC-01 §3.
//!
//! The tree keeps source order and carries no semantic defaults: an omitted `runtime` is
//! simply absent, and the checker (L03) materializes defaults in the IR. Every node that
//! stands for source text has a [`Span`] covering exactly that text (comments excluded).
//!
//! Comments are trivia on [`Item`]s and [`Block`]s: full-line comments before an item are
//! its `leading` comments, a comment after an item on the same line is its `trailing`
//! comment, and comments before a block's `}` are the block's `end_comments`. Comments
//! written between the tokens of a single item are kept with that item's leading comments.

use serde::Serialize;

use crate::span::Span;

/// The largest money literal, in micro-USD (2^53 − 1; SPEC-01 §4.8).
pub const MAX_MONEY_MICROS: u64 = 9_007_199_254_740_991;

/// A parsed `.maru` file: exactly one org.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct File {
    /// The org declaration, with any comments before it as leading trivia.
    pub org: Item<Org>,
    /// Comments after the org block that are not on its closing line.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub trailing_comments: Vec<Comment>,
}

/// A `#` comment. `text` includes the `#` and runs to the end of the line (no line
/// terminator), so it equals the source slice at `span`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Comment {
    /// The comment text, starting with `#`.
    pub text: String,
    /// Where the comment is.
    pub span: Span,
}

/// A line-oriented item (an org, block member, or block) with its comments.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Item<K> {
    /// What the item is.
    pub node: K,
    /// Comments on their own lines before the item, and comments inside it.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub leading: Vec<Comment>,
    /// A comment after the item on the line where it ends.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trailing: Option<Comment>,
    /// From the item's first keyword to its last token (`}` for blocks).
    pub span: Span,
}

/// A `{ … }` block of items.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Block<K> {
    /// The items in source order.
    pub items: Vec<Item<K>>,
    /// A comment after `{` on the same line, before the first item.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_comment: Option<Comment>,
    /// Comments after the last item, before `}`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub end_comments: Vec<Comment>,
    /// From `{` to `}`.
    pub span: Span,
}

/// `org "<name>" { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Org {
    /// The org's display name.
    pub name: Str,
    /// Org items.
    pub body: Block<OrgItem>,
}

/// An item directly inside `org { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OrgItem {
    /// `purpose "<text>"`.
    Purpose(Str),
    /// `members: <membership>`.
    Members(Membership),
    /// `amend: <procedure> [<timeout>]`.
    Amend(Amend),
    /// `circle <id> { … }`.
    Circle(Circle),
    /// `agent <id> { … }`.
    Agent(Agent),
    /// `goal <id> "<title>" { … }`.
    Goal(Goal),
}

/// `amend: <procedure> [<timeout>]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Amend {
    /// The decision procedure for changes to the spec.
    pub procedure: Procedure,
    /// `within … else …`, if written.
    pub timeout: Option<Timeout>,
}

/// `open()` or `invite(sponsors: N)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Membership {
    /// Which form.
    pub kind: MembershipKind,
    /// From `open`/`invite` to `)`.
    pub span: Span,
}

/// The membership forms.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MembershipKind {
    /// `open()`.
    Open,
    /// `invite(sponsors: N)`.
    Invite {
        /// Required distinct sponsors.
        sponsors: Int,
    },
}

/// `circle <id> { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Circle {
    /// Circle id.
    pub id: Ident,
    /// Circle items.
    pub body: Block<CircleItem>,
}

/// An item inside `circle { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CircleItem {
    /// `seats: N`.
    Seats(Int),
    /// `term: <duration>`.
    Term(Duration),
    /// `holders: @a, @b`.
    Holders(Vec<Handle>),
}

/// `agent <id> { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Agent {
    /// Agent id.
    pub id: Ident,
    /// Agent items.
    pub body: Block<AgentItem>,
}

/// An item inside `agent { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentItem {
    /// `operator: @handle`.
    Operator(Handle),
    /// `runtime: byo | hosted`.
    Runtime(Runtime),
}

/// Where an agent runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Runtime {
    /// `byo`: the operator's own infrastructure.
    Byo,
    /// `hosted`: openmaru's hosted runtime.
    Hosted,
}

/// `goal <id> "<title>" { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Goal {
    /// Goal id.
    pub id: Ident,
    /// Goal title.
    pub title: Str,
    /// Goal items.
    pub body: Block<GoalItem>,
}

/// An item inside `goal { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GoalItem {
    /// `steward: <circle>`.
    Steward(Ident),
    /// `purpose "<text>"`.
    Purpose(Str),
    /// `fund: usd X (/ period | once) from treasury`.
    Fund(Fund),
    /// `on_underfunded: pause | continue`.
    OnUnderfunded(Underfunded),
    /// `on_close: return treasury | transfer <goal>`.
    OnClose(OnClose),
    /// `success: metric(<name>) <cmp> <value> [by <date>]`.
    Success(Success),
    /// `mandate <principal> { … }`.
    Mandate(Mandate),
    /// `rule <subject> requires <procedure> [<timeout>]`.
    Rule(Rule),
}

/// `usd X / period from treasury` or `usd X once from treasury`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fund {
    /// Amount allocated each time.
    pub amount: Money,
    /// Per period or once.
    pub schedule: FundSchedule,
    /// From `usd` to `treasury`.
    pub span: Span,
}

/// When a goal's `fund` is allocated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FundSchedule {
    /// `/ day`, `/ week`, `/ month`.
    Every(Period),
    /// `once`.
    Once,
}

/// `on_underfunded` policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Underfunded {
    /// `pause`.
    Pause,
    /// `continue`.
    Continue,
}

/// `on_close` policy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OnClose {
    /// `return treasury`.
    ReturnTreasury,
    /// `transfer <goal>`.
    Transfer(Ident),
}

/// `metric(<name>) <cmp> <value> [by <date>]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Success {
    /// Metric name.
    pub metric: Ident,
    /// Comparator.
    pub cmp: Cmp,
    /// Target value.
    pub value: Signed,
    /// Deadline, if written.
    pub by: Option<Date>,
    /// From `metric` to the value or date.
    pub span: Span,
}

/// A success comparator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
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

impl Cmp {
    /// The comparator as written.
    pub const fn as_str(self) -> &'static str {
        match self {
            Cmp::Ge => ">=",
            Cmp::Gt => ">",
            Cmp::Le => "<=",
            Cmp::Lt => "<",
            Cmp::Eq => "==",
        }
    }
}

/// `mandate <principal> { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Mandate {
    /// Who holds the mandate.
    pub principal: Principal,
    /// Mandate items.
    pub body: Block<MandateItem>,
}

/// A mandate's principal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Principal {
    /// A declared agent, by id.
    Agent(Ident),
    /// A person, by `@handle`.
    Person(Handle),
}

/// An item inside `mandate { … }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MandateItem {
    /// `spend <category> <= usd X / period`.
    Spend(SpendLimit),
    /// `per_request <= usd X`.
    PerRequest(Money),
    /// `can: <capability>, …`.
    Can(Vec<Capability>),
    /// `expires: <date>`.
    Expires(Date),
}

/// `spend <category> <= usd X / period`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SpendLimit {
    /// Spend category.
    pub category: Category,
    /// Cumulative limit per period.
    pub limit: Money,
    /// The UTC calendar period.
    pub period: Period,
}

/// A capability in `can:`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Capability {
    /// Which capability.
    pub kind: CapabilityKind,
    /// The capability's text.
    pub span: Span,
}

/// The capabilities.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityKind {
    /// `claim_tasks`.
    ClaimTasks,
    /// `create_tasks`.
    CreateTasks,
    /// `post_evidence`.
    PostEvidence,
    /// `report_metric(<name>)`.
    ReportMetric(Ident),
}

/// `rule <subject> requires <procedure> [<timeout>]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Rule {
    /// What the rule gates.
    pub subject: Subject,
    /// The approving decision.
    pub procedure: Procedure,
    /// `within … else …`, if written.
    pub timeout: Option<Timeout>,
}

/// A rule subject.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Subject {
    /// Which subject.
    pub kind: SubjectKind,
    /// From `spend`/`close` to the subject's last token.
    pub span: Span,
}

/// The rule subjects.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SubjectKind {
    /// `spend [category] [> usd X]`.
    Spend {
        /// Category filter; `None` matches every category.
        category: Option<Category>,
        /// Strict lower bound; `None` matches every amount.
        over: Option<Money>,
    },
    /// `close`.
    Close,
}

/// A decision procedure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Procedure {
    /// Which procedure.
    pub kind: ProcedureKind,
    /// From `approve`/`vote` to `)`.
    pub span: Span,
}

/// The decision procedures.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcedureKind {
    /// `approve(<circle>, N)`. The parser also accepts `members` here so the checker
    /// can report E322.
    Approve {
        /// Approving circle.
        group: Group,
        /// Distinct approvals needed.
        count: Int,
    },
    /// `vote(<circle> | members, <threshold>)`.
    Vote {
        /// Eligible voters.
        group: Group,
        /// Share of yes votes needed.
        threshold: Threshold,
    },
}

/// Who takes part in a decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Group {
    /// A circle, by id.
    Circle(Ident),
    /// `members`: every member of the org.
    Members {
        /// The `members` keyword.
        span: Span,
    },
}

/// `within <duration> else deny | allow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Timeout {
    /// Deadline after creation.
    pub within: Duration,
    /// Outcome at the deadline.
    pub outcome: Outcome,
    /// From `within` to `deny`/`allow`.
    pub span: Span,
}

/// A timeout's outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// `else deny`.
    Deny,
    /// `else allow`.
    Allow,
}

/// A vote threshold. Range checks (E308) belong to the checker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Threshold {
    /// Which form.
    pub kind: ThresholdKind,
    /// From the first number to the last token.
    pub span: Span,
}

/// The threshold forms.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ThresholdKind {
    /// `a/b`.
    Fraction {
        /// Numerator.
        num: Int,
        /// Denominator.
        den: Int,
    },
    /// `p%`.
    Percent {
        /// Percentage.
        value: Int,
    },
}

impl Threshold {
    /// The threshold as an unreduced fraction `(num, den)`; `60%` is `(60, 100)`.
    pub fn as_fraction(&self) -> (u64, u64) {
        match &self.kind {
            ThresholdKind::Fraction { num, den } => (num.value, den.value),
            ThresholdKind::Percent { value } => (value.value, 100),
        }
    }
}

/// A spend category.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    /// `llm`: model calls through the gateway.
    Llm,
    /// `compute`: hosted runtime sessions.
    Compute,
    /// `expense`: expense claims.
    Expense,
}

/// A UTC calendar period.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Period {
    /// `day`.
    Day,
    /// `week` (ISO, starting Monday).
    Week,
    /// `month`.
    Month,
}

/// An identifier: `[a-z][a-z0-9_]*`, at most 40 characters, not a keyword.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Ident {
    /// The identifier.
    pub name: String,
    /// Where it is.
    pub span: Span,
}

/// A user handle, `@name`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Handle {
    /// The handle without `@`.
    pub name: String,
    /// Where it is, including `@`.
    pub span: Span,
}

/// A string literal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Str {
    /// The unescaped contents.
    pub value: String,
    /// Where it is, including the quotes.
    pub span: Span,
}

/// An unsigned integer literal (counts, seats, threshold parts).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Int {
    /// The value (digit-group underscores removed).
    pub value: u64,
    /// Where it is.
    pub span: Span,
}

/// A money literal, `usd X`.
///
/// Only the value is kept, so `usd 12000` and `usd 12_000` are equal, as the formatter's
/// AST-preservation property requires (SPEC-01 §7). The text as written is the source at
/// `span`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Money {
    /// The exact value in micro-USD (at most 6 decimals and at most
    /// [`MAX_MONEY_MICROS`], otherwise the parser reports E311/E310).
    pub micros: u64,
    /// From `usd` to the end of the number.
    pub span: Span,
}

/// A signed decimal metric value (`SIGNED`), kept as digits so no precision is lost.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Signed {
    /// Whether it starts with `-`.
    pub negative: bool,
    /// Integer digits, underscores removed.
    pub int: String,
    /// Fraction digits after `.`, if any.
    pub frac: Option<String>,
    /// From `-` (if any) to the last digit.
    pub span: Span,
}

/// A duration literal such as `48h`; keeps its source unit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Duration {
    /// The count of `unit`s.
    pub value: u64,
    /// The unit as written.
    pub unit: DurationUnit,
    /// Where it is.
    pub span: Span,
}

impl Duration {
    /// Length in seconds (`value × unit`), saturating; the parser rejects literals whose
    /// seconds overflow `u64` (E104).
    pub fn secs(&self) -> u64 {
        self.value.saturating_mul(self.unit.secs())
    }
}

/// A duration unit (SPEC-01 §4.8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub enum DurationUnit {
    /// `m`: 60 s.
    #[serde(rename = "m")]
    Minutes,
    /// `h`: 3600 s.
    #[serde(rename = "h")]
    Hours,
    /// `d`: 86400 s.
    #[serde(rename = "d")]
    Days,
    /// `w`: 7 days.
    #[serde(rename = "w")]
    Weeks,
    /// `y`: 365 days.
    #[serde(rename = "y")]
    Years,
}

impl DurationUnit {
    /// Seconds in one unit.
    pub const fn secs(self) -> u64 {
        match self {
            DurationUnit::Minutes => 60,
            DurationUnit::Hours => 3_600,
            DurationUnit::Days => 86_400,
            DurationUnit::Weeks => 604_800,
            DurationUnit::Years => 31_536_000,
        }
    }

    /// The unit letter as written.
    pub const fn as_char(self) -> char {
        match self {
            DurationUnit::Minutes => 'm',
            DurationUnit::Hours => 'h',
            DurationUnit::Days => 'd',
            DurationUnit::Weeks => 'w',
            DurationUnit::Years => 'y',
        }
    }

    /// The unit for a letter, if it is one.
    pub const fn from_char(c: char) -> Option<DurationUnit> {
        match c {
            'm' => Some(DurationUnit::Minutes),
            'h' => Some(DurationUnit::Hours),
            'd' => Some(DurationUnit::Days),
            'w' => Some(DurationUnit::Weeks),
            'y' => Some(DurationUnit::Years),
            _ => None,
        }
    }
}

/// A calendar date, `YYYY-MM-DD` (valid Gregorian, years 2000–2999).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Date {
    /// Year, 2000–2999.
    pub year: u16,
    /// Month, 1–12.
    pub month: u8,
    /// Day of month.
    pub day: u8,
    /// Where it is.
    pub span: Span,
}

impl Date {
    /// The date as `YYYY-MM-DD`.
    pub fn to_iso(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}
