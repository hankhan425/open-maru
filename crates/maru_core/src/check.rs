//! The checker (SPEC-01 §5): validates a source and lowers it to the IR (SPEC-01 §6).
//!
//! Checking has two stages. Stage 1 parses the source (E1xx, E2xx, E310, E311) and formats
//! the tree for the spec hash (E109 when the formatted source would exceed 256 KiB); any
//! error there is returned alone, with no semantic checks, because the parser leaves
//! erroneous items out of the tree. Stage 2 runs the semantic checks (the other E3xx codes
//! and all W4xx) while lowering the tree to the IR, which is returned only when no error was
//! found.
//!
//! A value that is already reported is not checked again for what follows from it: a
//! duplicate field's second occurrence is ignored, a circle with an invalid seat count is
//! not compared with its holders, and so on, so one mistake gives one diagnostic.
//! Diagnostics are sorted by span start; ties keep the order in which they were found, so
//! the output is deterministic.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::ast::{self, Group, MAX_MONEY_MICROS};
use crate::diag::{Code, Diagnostic};
use crate::fmt::{format_ast, rule_line, sha256_hex};
use crate::ir::{self, IR_VERSION, Ir};
use crate::limits;
use crate::parser::parse;
use crate::span::Span;
use crate::suggest::Suggester;

/// Options for [`check`].
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct CheckOptions {
    /// The current time. Enables time-relative warnings (W401); without it they are
    /// skipped so checking stays deterministic.
    pub now: Option<DateTime<Utc>>,
}

/// The result of [`check`]: `{"diagnostics": […], "ir": {…} | null}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckOutput {
    /// Errors and warnings, sorted by span start.
    pub diagnostics: Vec<Diagnostic>,
    /// The IR, present exactly when there are no errors.
    pub ir: Option<Ir>,
}

/// Checks `src` and, when it has no errors, lowers it to the IR.
///
/// Never panics. With the same `src` and `opts`, the output is the same.
pub fn check(src: &str, opts: &CheckOptions) -> CheckOutput {
    let parsed = parse(src);
    let file = match parsed.file {
        Some(file) if !parsed.diagnostics.iter().any(Diagnostic::is_error) => file,
        // The parser reports an error whenever it finds no org.
        _ => {
            return CheckOutput {
                diagnostics: parsed.diagnostics,
                ir: None,
            };
        }
    };
    let formatted = match format_ast(&file) {
        Ok(text) => text,
        Err(d) => {
            return CheckOutput {
                diagnostics: vec![d],
                ir: None,
            };
        }
    };

    let mut checker = Checker::new(&file.org.node, opts);
    let org = checker.org();
    let mut diagnostics = parsed.diagnostics;
    diagnostics.append(&mut checker.diags);
    diagnostics.sort_by_key(|d| d.span.start.offset);
    let ir = match org {
        Some(org) if !diagnostics.iter().any(Diagnostic::is_error) => Some(Ir {
            ir_version: IR_VERSION,
            source_hash: format!("sha256:{}", sha256_hex(&formatted)),
            org,
        }),
        _ => None,
    };
    CheckOutput { diagnostics, ir }
}

/// What other items need to know about a circle: its first declaration's seats and
/// distinct holders.
#[derive(Debug, Clone, Copy)]
struct CircleInfo {
    seats: Option<u64>,
    holders: u64,
}

impl CircleInfo {
    fn of(c: &ast::Circle) -> CircleInfo {
        let seats = c.body.items.iter().find_map(|i| match &i.node {
            ast::CircleItem::Seats(n) => Some(n.value),
            _ => None,
        });
        let holders = c.body.items.iter().find_map(|i| match &i.node {
            ast::CircleItem::Holders(hs) => {
                Some(hs.iter().map(|h| &h.name).collect::<HashSet<_>>().len())
            }
            _ => None,
        });
        CircleInfo {
            seats,
            holders: holders.map_or(0, |n| u64::try_from(n).unwrap_or(u64::MAX)),
        }
    }

    /// Seats, when given and valid (≥ 1).
    fn valid_seats(self) -> Option<u64> {
        self.seats.filter(|s| *s >= 1)
    }
}

/// Ids declared in the org, first declaration only, in source order.
#[derive(Default)]
struct Names<'a> {
    order: Vec<&'a str>,
    first: HashMap<&'a str, Span>,
}

impl<'a> Names<'a> {
    /// Records `id`; returns the first declaration's span if it was already declared.
    fn declare(&mut self, id: &'a ast::Ident) -> Option<Span> {
        if let Some(first) = self.first.get(id.name.as_str()) {
            return Some(*first);
        }
        self.order.push(&id.name);
        self.first.insert(&id.name, id.span);
        None
    }

    fn contains(&self, name: &str) -> bool {
        self.first.contains_key(name)
    }
}

/// Tracks single-valued fields of one block for E305.
struct Fields {
    /// The block, for messages: "circle `core`".
    block: String,
    seen: Vec<(&'static str, Span)>,
}

impl Fields {
    fn new(block: impl Into<String>) -> Fields {
        Fields {
            block: block.into(),
            seen: Vec::new(),
        }
    }

    /// Whether this is the field's first occurrence; reports E305 otherwise.
    fn first(&mut self, diags: &mut Vec<Diagnostic>, key: &'static str, span: Span) -> bool {
        if let Some((_, first)) = self.seen.iter().find(|(k, _)| *k == key) {
            diags.push(
                Diagnostic::new(
                    Code::E305,
                    format!("`{key}` is given more than once in {}", self.block),
                    span,
                )
                .with_note(at("first given", *first)),
            );
            return false;
        }
        self.seen.push((key, span));
        true
    }
}

/// "first declared at line 3, column 10".
fn at(what: &str, span: Span) -> String {
    format!(
        "{what} at line {}, column {}",
        span.start.line, span.start.col
    )
}

fn did_you_mean_note(d: Diagnostic, suggestion: Option<&str>) -> Diagnostic {
    match suggestion {
        Some(s) => d.with_note(format!("did you mean `{s}`?")),
        None => d,
    }
}

/// A micro-USD amount in dollars, e.g. `9300000000` or `12.5`.
fn usd(micros: u128) -> String {
    let (whole, frac) = (micros / 1_000_000, micros % 1_000_000);
    if frac == 0 {
        return whole.to_string();
    }
    let frac = format!("{frac:06}");
    format!("{whole}.{}", frac.trim_end_matches('0'))
}

/// A count that the parser bounds by [`ast::MAX_INT`], as a `u32`.
fn count(n: &ast::Int) -> u32 {
    u32::try_from(n.value).unwrap_or(u32::MAX)
}

/// The key that makes two rules' subjects the same (E314).
#[derive(PartialEq, Eq, Hash)]
enum SubjectKey {
    Close,
    Spend(Option<ast::Category>, Option<u64>),
}

struct Checker<'a> {
    org: &'a ast::Org,
    now: Option<NaiveDate>,
    diags: Vec<Diagnostic>,
    circles: Names<'a>,
    circle_info: HashMap<&'a str, CircleInfo>,
    agents: Names<'a>,
    goals: Names<'a>,
    /// Declared agents that hold a mandate somewhere (W406).
    agents_with_mandates: HashSet<&'a str>,
    /// "Did you mean" lookups, under one work budget per check.
    suggester: Suggester,
}

impl<'a> Checker<'a> {
    fn new(org: &'a ast::Org, opts: &CheckOptions) -> Checker<'a> {
        Checker {
            org,
            now: opts.now.map(|now| now.date_naive()),
            diags: Vec::new(),
            circles: Names::default(),
            circle_info: HashMap::new(),
            agents: Names::default(),
            goals: Names::default(),
            agents_with_mandates: HashSet::new(),
            suggester: Suggester::new(Suggester::CHECK_BUDGET),
        }
    }

    fn report(&mut self, d: Diagnostic) {
        self.diags.push(d);
    }

    fn error(&mut self, code: Code, message: String, span: Span) {
        self.report(Diagnostic::new(code, message, span));
    }

    // ---- org ----

    /// Checks the org and lowers it; `None` when a required part is missing.
    fn org(&mut self) -> Option<ir::Org> {
        let org = self.org;
        self.declare();
        let mut fields = Fields::new("the org");
        let mut purpose = None;
        let mut membership = None;
        let mut amend = None;
        let mut circles = Vec::new();
        let mut agents = Vec::new();
        let mut goals = Vec::new();
        for item in &org.body.items {
            match &item.node {
                ast::OrgItem::Purpose(s) => {
                    if fields.first(&mut self.diags, "purpose", item.span) {
                        purpose = Some(s.value.clone());
                    }
                }
                ast::OrgItem::Members(m) => {
                    if fields.first(&mut self.diags, "members", item.span) {
                        membership = Some(self.membership(m));
                    }
                }
                ast::OrgItem::Amend(a) => {
                    if fields.first(&mut self.diags, "amend", item.span) {
                        amend = Some(self.amend(a));
                    }
                }
                ast::OrgItem::Circle(c) => circles.push(self.circle(c)),
                ast::OrgItem::Agent(a) => agents.push(self.agent(a)),
                ast::OrgItem::Goal(g) => goals.push(self.goal(g)),
            }
        }
        if amend.is_none() {
            self.error(
                Code::E304,
                "missing `amend`: the org must say how its spec is changed".to_string(),
                org.name.span,
            );
        }
        self.unused_agents();
        Some(ir::Org {
            name: org.name.value.clone(),
            purpose,
            membership: membership.unwrap_or(ir::Membership::Invite { sponsors: 1 }),
            amend: amend?,
            circles: circles.into_iter().collect::<Option<_>>()?,
            agents: agents.into_iter().collect::<Option<_>>()?,
            goals: goals.into_iter().collect::<Option<_>>()?,
        })
    }

    /// Records every circle, agent and goal id (E301 for repeats), so references can be
    /// resolved wherever they are written.
    fn declare(&mut self) {
        let org = self.org;
        for item in &org.body.items {
            let (names, id, kind) = match &item.node {
                ast::OrgItem::Circle(c) => (&mut self.circles, &c.id, "circle"),
                ast::OrgItem::Agent(a) => (&mut self.agents, &a.id, "agent"),
                ast::OrgItem::Goal(g) => (&mut self.goals, &g.id, "goal"),
                _ => continue,
            };
            match names.declare(id) {
                Some(first) => {
                    let d = Diagnostic::new(
                        Code::E301,
                        format!("duplicate {kind} `{}`", id.name),
                        id.span,
                    )
                    .with_note(at("first declared", first));
                    self.report(d);
                }
                None => {
                    if let ast::OrgItem::Circle(c) = &item.node {
                        self.circle_info.insert(&c.id.name, CircleInfo::of(c));
                    }
                }
            }
        }
    }

    fn membership(&mut self, m: &ast::Membership) -> ir::Membership {
        match &m.kind {
            ast::MembershipKind::Open => ir::Membership::Open,
            ast::MembershipKind::Invite { sponsors } => {
                if sponsors.value == 0 {
                    self.error(
                        Code::E324,
                        "`sponsors` must be at least 1".to_string(),
                        sponsors.span,
                    );
                }
                ir::Membership::Invite {
                    sponsors: count(sponsors),
                }
            }
        }
    }

    fn amend(&mut self, a: &ast::Amend) -> ir::Amend {
        let procedure = self.procedure(&a.procedure);
        self.deadlock(&a.procedure);
        let (within, otherwise) = self.timeout(a.timeout.as_ref(), "changes the spec");
        ir::Amend {
            procedure,
            within,
            otherwise,
        }
    }

    /// E316: an `amend` procedure that the declared holders can never pass.
    fn deadlock(&mut self, p: &ast::Procedure) {
        let message = match &p.kind {
            ast::ProcedureKind::Approve {
                group: Group::Circle(id),
                count,
            } => {
                let Some(info) = self.circle_info.get(id.name.as_str()).copied() else {
                    return;
                };
                let Some(seats) = info.valid_seats() else {
                    return;
                };
                // Counts outside 1..=seats are already E307.
                if count.value == 0 || count.value > seats || count.value <= info.holders {
                    return;
                }
                format!(
                    "amendments can never pass: they need {} approvals from `{}`, which has {} holder{}",
                    count.value,
                    id.name,
                    info.holders,
                    if info.holders == 1 { "" } else { "s" }
                )
            }
            ast::ProcedureKind::Vote {
                group: Group::Circle(id),
                ..
            } => {
                let Some(info) = self.circle_info.get(id.name.as_str()).copied() else {
                    return;
                };
                if info.valid_seats().is_none() || info.holders > 0 {
                    return;
                }
                format!(
                    "amendments can never pass: `{}` has no holders to vote",
                    id.name
                )
            }
            _ => return,
        };
        self.error(Code::E316, message, p.span);
    }

    // ---- circles and agents ----

    fn circle(&mut self, c: &'a ast::Circle) -> Option<ir::Circle> {
        let mut fields = Fields::new(format!("circle `{}`", c.id.name));
        let mut seats = None;
        let mut term = None;
        let mut holders: Option<(Vec<String>, Span)> = None;
        for item in &c.body.items {
            match &item.node {
                ast::CircleItem::Seats(n) => {
                    if fields.first(&mut self.diags, "seats", item.span) {
                        if n.value == 0 {
                            self.error(
                                Code::E324,
                                "`seats` must be at least 1".to_string(),
                                n.span,
                            );
                        }
                        seats = Some(n);
                    }
                }
                ast::CircleItem::Term(d) => {
                    if fields.first(&mut self.diags, "term", item.span) {
                        self.positive(d);
                        term = Some(ir::Duration::from(d));
                    }
                }
                ast::CircleItem::Holders(hs) => {
                    if fields.first(&mut self.diags, "holders", item.span) {
                        holders = Some((self.holders(&c.id, hs), item.span));
                    }
                }
            }
        }
        match (seats, &holders) {
            (None, _) => self.error(
                Code::E304,
                format!("circle `{}` has no `seats`", c.id.name),
                c.id.span,
            ),
            (Some(n), Some((names, span))) if n.value >= 1 => {
                let held = u64::try_from(names.len()).unwrap_or(u64::MAX);
                if held > n.value {
                    let message = format!(
                        "circle `{}` has {held} holders but only {} seat{}",
                        c.id.name,
                        n.value,
                        if n.value == 1 { "" } else { "s" }
                    );
                    self.error(Code::E306, message, *span);
                }
            }
            _ => {}
        }
        Some(ir::Circle {
            id: c.id.name.clone(),
            seats: count(seats?),
            term,
            holders: holders.map(|(names, _)| names).unwrap_or_default(),
        })
    }

    /// The distinct holders in order; E323 for repeats.
    fn holders(&mut self, circle: &ast::Ident, hs: &[ast::Handle]) -> Vec<String> {
        let mut first: HashMap<&str, Span> = HashMap::new();
        let mut names = Vec::new();
        for h in hs {
            if let Some(span) = first.get(h.name.as_str()) {
                let d = Diagnostic::new(
                    Code::E323,
                    format!("`@{}` is listed twice in circle `{}`", h.name, circle.name),
                    h.span,
                )
                .with_note(at("first listed", *span));
                self.report(d);
            } else {
                first.insert(&h.name, h.span);
                names.push(h.name.clone());
            }
        }
        names
    }

    fn agent(&mut self, a: &ast::Agent) -> Option<ir::Agent> {
        let mut fields = Fields::new(format!("agent `{}`", a.id.name));
        let mut operator = None;
        let mut runtime = None;
        for item in &a.body.items {
            match &item.node {
                ast::AgentItem::Operator(h) => {
                    if fields.first(&mut self.diags, "operator", item.span) {
                        operator = Some(h.name.clone());
                    }
                }
                ast::AgentItem::Runtime(r) => {
                    if fields.first(&mut self.diags, "runtime", item.span) {
                        runtime = Some(ir::Runtime::from(*r));
                    }
                }
            }
        }
        if operator.is_none() {
            self.error(
                Code::E304,
                format!("agent `{}` has no `operator`", a.id.name),
                a.id.span,
            );
        }
        Some(ir::Agent {
            id: a.id.name.clone(),
            operator: operator?,
            runtime: runtime.unwrap_or(ir::Runtime::Byo),
        })
    }

    /// W406 for every declared agent that holds no mandate.
    fn unused_agents(&mut self) {
        let unused: Vec<(&str, Span)> = self
            .agents
            .order
            .iter()
            .filter(|name| !self.agents_with_mandates.contains(*name))
            .filter_map(|name| Some((*name, *self.agents.first.get(name)?)))
            .collect();
        for (name, span) in unused {
            self.report(Diagnostic::new(
                Code::W406,
                format!("agent `{name}` holds no mandate in any goal"),
                span,
            ));
        }
    }

    // ---- goals ----

    fn goal(&mut self, g: &'a ast::Goal) -> Option<ir::Goal> {
        let mut fields = Fields::new(format!("goal `{}`", g.id.name));
        let mut steward = None;
        let mut purpose = None;
        let mut fund: Option<&ast::Fund> = None;
        let mut underfunded = None;
        let mut on_close = None;
        let mut success = None;
        for item in &g.body.items {
            let span = item.span;
            match &item.node {
                ast::GoalItem::Steward(id) => {
                    if fields.first(&mut self.diags, "steward", span) {
                        self.steward(id);
                        steward = Some(id.name.clone());
                    }
                }
                ast::GoalItem::Purpose(s) => {
                    if fields.first(&mut self.diags, "purpose", span) {
                        purpose = Some(s.value.clone());
                    }
                }
                ast::GoalItem::Fund(f) => {
                    if fields.first(&mut self.diags, "fund", span) {
                        self.money(&f.amount);
                        fund = Some(f);
                    }
                }
                ast::GoalItem::OnUnderfunded(u) => {
                    if fields.first(&mut self.diags, "on_underfunded", span) {
                        underfunded = Some((ir::Underfunded::from(*u), span));
                    }
                }
                ast::GoalItem::OnClose(c) => {
                    if fields.first(&mut self.diags, "on_close", span) {
                        on_close = Some(self.on_close(g, c));
                    }
                }
                ast::GoalItem::Success(s) => {
                    if fields.first(&mut self.diags, "success", span) {
                        success = Some(ir::Success::from(s));
                    }
                }
                ast::GoalItem::Mandate(_) | ast::GoalItem::Rule(_) => {}
            }
        }
        if steward.is_none() {
            self.error(
                Code::E304,
                format!("goal `{}` has no `steward`", g.id.name),
                g.id.span,
            );
        }
        if let (Some((_, span)), None) = (underfunded, fund) {
            let message = format!(
                "`on_underfunded` has no effect: goal `{}` has no `fund`",
                g.id.name
            );
            self.report(Diagnostic::new(Code::W404, message, span));
        }

        // The fund per month, to compare spend limits with (W403); `once` is not periodic.
        let fund_monthly = fund.and_then(|f| match f.schedule {
            ast::FundSchedule::Every(p) if f.amount.micros > 0 => {
                Some(u128::from(f.amount.micros) * u128::from(limits::factor(ir::Period::from(p))))
            }
            _ => None,
        });
        let mut mandates = Vec::new();
        let mut principals: HashMap<(ir::PrincipalKind, &str), Span> = HashMap::new();
        let mut rules = Vec::new();
        let mut subjects: HashMap<SubjectKey, Span> = HashMap::new();
        for item in &g.body.items {
            match &item.node {
                ast::GoalItem::Mandate(m) => {
                    mandates.push(self.mandate(g, m, fund_monthly, &mut principals));
                }
                ast::GoalItem::Rule(r) => rules.push(self.rule(g, r, &mut subjects)),
                _ => {}
            }
        }

        let monthly = limits::unapproved_monthly_max(&mandates, &rules);
        if monthly > u128::from(MAX_MONEY_MICROS) {
            let message = format!(
                "goal `{}` can spend up to {} USD per month without approval, more than the maximum amount of {} USD",
                g.id.name,
                usd(monthly),
                usd(u128::from(MAX_MONEY_MICROS))
            );
            self.error(Code::E318, message, g.id.span);
        }

        Some(ir::Goal {
            id: g.id.name.clone(),
            title: g.title.value.clone(),
            purpose,
            steward: steward?,
            fund: fund.map(ir::Fund::from),
            on_underfunded: underfunded.map_or(ir::Underfunded::Pause, |(u, _)| u),
            on_close: on_close.unwrap_or(ir::OnClose::ReturnTreasury),
            success,
            mandates,
            rules,
            limits: ir::Limits {
                unapproved_monthly_max_micros: u64::try_from(monthly).unwrap_or(u64::MAX),
            },
        })
    }

    /// E302 for an unknown steward circle, E317 for one without holders.
    fn steward(&mut self, id: &ast::Ident) {
        match self.circle_info.get(id.name.as_str()) {
            None => self.unknown_circle(id, false),
            Some(info) if info.holders == 0 => {
                let message = format!("steward circle `{}` has no holders", id.name);
                self.error(Code::E317, message, id.span);
            }
            Some(_) => {}
        }
    }

    fn on_close(&mut self, g: &ast::Goal, c: &ast::OnClose) -> ir::OnClose {
        match c {
            ast::OnClose::ReturnTreasury => ir::OnClose::ReturnTreasury,
            ast::OnClose::Transfer(id) => {
                if id.name == g.id.name {
                    let message = format!(
                        "goal `{}` cannot transfer its remaining funds to itself",
                        g.id.name
                    );
                    self.error(Code::E315, message, id.span);
                } else if !self.goals.contains(&id.name) {
                    let others = self.goals.order.iter().copied().filter(|n| *n != g.id.name);
                    let suggestion = self.suggester.did_you_mean(&id.name, others);
                    let d =
                        Diagnostic::new(Code::E315, format!("unknown goal `{}`", id.name), id.span);
                    self.report(did_you_mean_note(d, suggestion));
                }
                ir::OnClose::Transfer {
                    goal: id.name.clone(),
                }
            }
        }
    }

    // ---- mandates ----

    fn mandate(
        &mut self,
        g: &ast::Goal,
        m: &'a ast::Mandate,
        fund_monthly: Option<u128>,
        principals: &mut HashMap<(ir::PrincipalKind, &'a str), Span>,
    ) -> ir::Mandate {
        let (kind, name, span, shown) = match &m.principal {
            ast::Principal::Agent(id) => {
                (ir::PrincipalKind::Agent, &id.name, id.span, id.name.clone())
            }
            ast::Principal::Person(h) => (
                ir::PrincipalKind::Person,
                &h.name,
                h.span,
                format!("@{}", h.name),
            ),
        };
        if kind == ir::PrincipalKind::Agent {
            if let Some((known, _)) = self.agents.first.get_key_value(name.as_str()) {
                self.agents_with_mandates.insert(known);
            } else {
                let d = Diagnostic::new(Code::E303, format!("unknown agent `{name}`"), span);
                let suggestion = self
                    .suggester
                    .did_you_mean(name, self.agents.order.iter().copied());
                self.report(did_you_mean_note(d, suggestion));
            }
        }
        match principals.get(&(kind, name.as_str())) {
            Some(first) => {
                let message = format!("`{shown}` already has a mandate in goal `{}`", g.id.name);
                let d = Diagnostic::new(Code::E312, message, span)
                    .with_note(at("first mandate", *first));
                self.report(d);
            }
            None => {
                principals.insert((kind, name), span);
            }
        }

        let mut fields = Fields::new(format!("the mandate for `{shown}`"));
        let mut spend: Vec<(ir::SpendLimit, Span)> = Vec::new();
        let mut per_request: Option<(u64, Span)> = None;
        let mut capabilities = Vec::new();
        let mut expires = None;
        for item in &m.body.items {
            match &item.node {
                ast::MandateItem::Spend(line) => {
                    self.money(&line.limit);
                    let category = ir::Category::from(line.category);
                    match spend.iter().find(|(l, _)| l.category == category) {
                        Some((_, first)) => {
                            let message = format!(
                                "`spend {}` is given twice in the mandate for `{shown}`",
                                category_name(line.category)
                            );
                            let d = Diagnostic::new(Code::E313, message, item.span)
                                .with_note(at("first given", *first));
                            self.report(d);
                        }
                        None => spend.push((ir::SpendLimit::from(line), item.span)),
                    }
                }
                ast::MandateItem::PerRequest(money) => {
                    if fields.first(&mut self.diags, "per_request", item.span) {
                        self.money(money);
                        per_request = Some((money.micros, item.span));
                    }
                }
                ast::MandateItem::Can(caps) => {
                    if fields.first(&mut self.diags, "can", item.span) {
                        capabilities = self.capabilities(caps);
                    }
                }
                ast::MandateItem::Expires(date) => {
                    if fields.first(&mut self.diags, "expires", item.span) {
                        self.expiry(date);
                        expires = Some(date.to_iso());
                    }
                }
            }
        }

        if let Some(fund) = fund_monthly {
            for (line, span) in &spend {
                let monthly =
                    u128::from(line.limit_micros) * u128::from(limits::factor(line.period));
                if line.limit_micros > 0 && monthly > fund {
                    let message = format!(
                        "this limit allows up to {} USD per month, more than the goal's fund of {} USD per month",
                        usd(monthly),
                        usd(fund)
                    );
                    self.report(Diagnostic::new(Code::W403, message, *span));
                }
            }
        }
        if let Some((cap, span)) = per_request {
            if cap > 0 && !spend.is_empty() && spend.iter().all(|(l, _)| cap > l.limit_micros) {
                let message =
                    "`per_request` has no effect: it exceeds every spend limit of this mandate";
                self.report(Diagnostic::new(Code::W405, message, span));
            }
        }

        ir::Mandate {
            principal: ir::Principal {
                kind,
                id: name.clone(),
            },
            spend: spend.into_iter().map(|(line, _)| line).collect(),
            per_request_micros: per_request.map(|(micros, _)| micros),
            capabilities,
            expires,
        }
    }

    /// The capabilities without repeats, in order; W408 for each repeat.
    fn capabilities(&mut self, caps: &[ast::Capability]) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        let mut first: HashMap<String, Span> = HashMap::new();
        for c in caps {
            // The IR name, and the name as written for messages.
            let (name, written) = match &c.kind {
                ast::CapabilityKind::ClaimTasks => ("claim_tasks".to_string(), None),
                ast::CapabilityKind::CreateTasks => ("create_tasks".to_string(), None),
                ast::CapabilityKind::PostEvidence => ("post_evidence".to_string(), None),
                ast::CapabilityKind::ReportMetric(m) => (
                    format!("report_metric:{}", m.name),
                    Some(format!("report_metric({})", m.name)),
                ),
            };
            match first.get(&name) {
                Some(span) => {
                    let message = format!(
                        "capability `{}` is listed twice",
                        written.as_deref().unwrap_or(&name)
                    );
                    let d = Diagnostic::new(Code::W408, message, c.span)
                        .with_note(at("first listed", *span));
                    self.report(d);
                }
                None => {
                    first.insert(name.clone(), c.span);
                    names.push(name);
                }
            }
        }
        names
    }

    /// W401 when the mandate is no longer valid at `now` (from 00:00Z on its date).
    fn expiry(&mut self, date: &ast::Date) {
        let Some(now) = self.now else { return };
        let expires = NaiveDate::from_ymd_opt(
            i32::from(date.year),
            u32::from(date.month),
            u32::from(date.day),
        );
        if expires.is_some_and(|d| now >= d) {
            let message = format!("this mandate expired on {}", date.to_iso());
            self.report(Diagnostic::new(Code::W401, message, date.span));
        }
    }

    // ---- rules and procedures ----

    fn rule(
        &mut self,
        g: &ast::Goal,
        r: &ast::Rule,
        subjects: &mut HashMap<SubjectKey, Span>,
    ) -> ir::Rule {
        let (key, subject) = match &r.subject.kind {
            ast::SubjectKind::Close => (SubjectKey::Close, ir::Subject::Close),
            ast::SubjectKind::Spend { category, over } => {
                if let Some(m) = over {
                    self.money(m);
                }
                (
                    SubjectKey::Spend(*category, over.as_ref().map(|m| m.micros)),
                    ir::Subject::Spend {
                        category: category.map(ir::Category::from),
                        over_micros: over.as_ref().map(|m| m.micros),
                    },
                )
            }
        };
        match subjects.get(&key) {
            Some(first) => {
                let message = format!("goal `{}` already has a rule with this subject", g.id.name);
                let d = Diagnostic::new(Code::E314, message, r.subject.span)
                    .with_note(at("first rule", *first));
                self.report(d);
            }
            None => {
                subjects.insert(key, r.subject.span);
            }
        }
        let procedure = self.procedure(&r.procedure);
        let (within, otherwise) = self.timeout(r.timeout.as_ref(), "lets the request through");
        let mut hash = sha256_hex(&rule_line(r));
        hash.truncate(8);
        ir::Rule {
            id: format!("{}:r_{hash}", g.id.name),
            subject,
            procedure,
            within,
            otherwise,
        }
    }

    /// Checks a procedure (E302, E307, E308, E322) and lowers it.
    fn procedure(&mut self, p: &ast::Procedure) -> ir::Procedure {
        match &p.kind {
            ast::ProcedureKind::Approve { group, count: n } => {
                let circle = match group {
                    Group::Members { span } => {
                        let message =
                            "`approve` needs a circle; all members can only decide by `vote`";
                        self.error(Code::E322, message.to_string(), *span);
                        "members".to_string()
                    }
                    Group::Circle(id) => {
                        let seats = match self.circle_info.get(id.name.as_str()) {
                            Some(info) => info.valid_seats(),
                            None => {
                                self.unknown_circle(id, false);
                                None
                            }
                        };
                        if n.value == 0 {
                            let message = "`approve` needs at least 1 approval".to_string();
                            self.error(Code::E307, message, n.span);
                        } else if let Some(seats) = seats.filter(|s| n.value > *s) {
                            let message = format!(
                                "`approve` needs {} approvals but circle `{}` has only {seats} seat{}",
                                n.value,
                                id.name,
                                if seats == 1 { "" } else { "s" }
                            );
                            self.error(Code::E307, message, n.span);
                        }
                        id.name.clone()
                    }
                };
                ir::Procedure::Approve {
                    circle,
                    count: count(n),
                }
            }
            ast::ProcedureKind::Vote { group, threshold } => {
                let circle = match group {
                    Group::Members { .. } => None,
                    Group::Circle(id) => {
                        if !self.circle_info.contains_key(id.name.as_str()) {
                            self.unknown_circle(id, true);
                        }
                        Some(id.name.clone())
                    }
                };
                ir::Procedure::Vote {
                    circle,
                    threshold: self.threshold(threshold),
                }
            }
        }
    }

    /// E302 with a suggestion from the declared circles (and `members` for a vote).
    fn unknown_circle(&mut self, id: &ast::Ident, members_allowed: bool) {
        let members = members_allowed.then_some("members");
        let candidates = self.circles.order.iter().copied().chain(members);
        let suggestion = self.suggester.did_you_mean(&id.name, candidates);
        let d = Diagnostic::new(Code::E302, format!("unknown circle `{}`", id.name), id.span);
        self.report(did_you_mean_note(d, suggestion));
    }

    /// E308 unless `0 < a/b ≤ 1` or `1 ≤ p ≤ 100`.
    fn threshold(&mut self, t: &ast::Threshold) -> ir::Threshold {
        let (valid, percent) = match &t.kind {
            ast::ThresholdKind::Fraction { num, den } => (
                num.value >= 1 && den.value >= 1 && num.value <= den.value,
                false,
            ),
            ast::ThresholdKind::Percent { value } => ((1..=100).contains(&value.value), true),
        };
        if !valid {
            let message = if percent {
                "threshold must be from 1% to 100%"
            } else {
                "threshold `a/b` must be more than 0 and at most 1"
            };
            self.error(Code::E308, message.to_string(), t.span);
        }
        let (num, den) = t.as_fraction();
        ir::Threshold {
            num: u32::try_from(num).unwrap_or(u32::MAX),
            den: u32::try_from(den).unwrap_or(u32::MAX),
            percent,
        }
    }

    /// The timeout with defaults (7d, deny); E319 for `0`, W402 for `else allow`.
    /// `allow_effect` completes "`else allow` …" in the warning.
    fn timeout(
        &mut self,
        t: Option<&ast::Timeout>,
        allow_effect: &str,
    ) -> (ir::Duration, ir::Outcome) {
        let Some(t) = t else {
            return (
                ir::Duration {
                    value: 7,
                    unit: ir::DurationUnit::Days,
                    secs: 7 * 86_400,
                },
                ir::Outcome::Deny,
            );
        };
        self.positive(&t.within);
        if t.outcome == ast::Outcome::Allow {
            let message = format!("`else allow` {allow_effect} when no decision is made in time");
            self.report(Diagnostic::new(Code::W402, message, t.span));
        }
        (ir::Duration::from(&t.within), ir::Outcome::from(t.outcome))
    }

    // ---- values ----

    /// E309 for a zero amount.
    fn money(&mut self, m: &ast::Money) {
        if m.micros == 0 {
            self.error(Code::E309, "amount must be more than 0".to_string(), m.span);
        }
    }

    /// E319 for a zero duration.
    fn positive(&mut self, d: &ast::Duration) {
        if d.value == 0 {
            self.error(
                Code::E319,
                "duration must be more than 0".to_string(),
                d.span,
            );
        }
    }
}

const fn category_name(c: ast::Category) -> &'static str {
    match c {
        ast::Category::Llm => "llm",
        ast::Category::Compute => "compute",
        ast::Category::Expense => "expense",
    }
}
