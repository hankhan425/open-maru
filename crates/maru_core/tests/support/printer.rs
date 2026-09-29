//! Test-only naive printer: one item per line, 2-space indentation, literals as stored in
//! the AST. Not the formatter (L02); it exists so property tests can round-trip ASTs.

use maru_core::ast::*;

/// Prints a whole file, comments included.
pub fn file(f: &File) -> String {
    let mut out = String::new();
    item(&mut out, 0, &f.org, org);
    for c in &f.trailing_comments {
        out.push_str(&c.text);
        out.push('\n');
    }
    out
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

/// Prints an item with its leading comments, its node, and its trailing comment.
fn item<K>(out: &mut String, depth: usize, it: &Item<K>, node: fn(&mut String, usize, &K)) {
    for c in &it.leading {
        indent(out, depth);
        out.push_str(&c.text);
        out.push('\n');
    }
    indent(out, depth);
    node(out, depth, &it.node);
    if let Some(c) = &it.trailing {
        out.push(' ');
        out.push_str(&c.text);
    }
    out.push('\n');
}

/// Prints `{`, the items one per line, and `}` (without a newline after `}`).
pub fn block<K>(out: &mut String, depth: usize, b: &Block<K>, node: fn(&mut String, usize, &K)) {
    out.push('{');
    if let Some(c) = &b.open_comment {
        out.push(' ');
        out.push_str(&c.text);
    }
    out.push('\n');
    for it in &b.items {
        item(out, depth + 1, it, node);
    }
    for c in &b.end_comments {
        indent(out, depth + 1);
        out.push_str(&c.text);
        out.push('\n');
    }
    indent(out, depth);
    out.push('}');
}

/// Prints `org "…" { … }`.
pub fn org(out: &mut String, depth: usize, o: &Org) {
    out.push_str("org ");
    out.push_str(&string(&o.name));
    out.push(' ');
    block(out, depth, &o.body, org_item);
}

/// Prints an org item's node.
pub fn org_item(out: &mut String, depth: usize, i: &OrgItem) {
    match i {
        OrgItem::Purpose(s) => out.push_str(&format!("purpose {}", string(s))),
        OrgItem::Members(m) => out.push_str(&format!("members: {}", membership(m))),
        OrgItem::Amend(a) => {
            out.push_str(&format!("amend: {}", procedure(&a.procedure)));
            if let Some(t) = &a.timeout {
                out.push(' ');
                out.push_str(&timeout(t));
            }
        }
        OrgItem::Circle(c) => {
            out.push_str(&format!("circle {} ", c.id.name));
            block(out, depth, &c.body, circle_item);
        }
        OrgItem::Agent(a) => {
            out.push_str(&format!("agent {} ", a.id.name));
            block(out, depth, &a.body, agent_item);
        }
        OrgItem::Goal(g) => {
            out.push_str(&format!("goal {} {} ", g.id.name, string(&g.title)));
            block(out, depth, &g.body, goal_item);
        }
    }
}

/// Prints a circle item's node.
pub fn circle_item(out: &mut String, _depth: usize, i: &CircleItem) {
    match i {
        CircleItem::Seats(n) => out.push_str(&format!("seats: {}", n.value)),
        CircleItem::Term(d) => out.push_str(&format!("term: {}", duration(d))),
        CircleItem::Holders(hs) => out.push_str(&format!(
            "holders: {}",
            hs.iter().map(handle).collect::<Vec<_>>().join(", ")
        )),
    }
}

/// Prints an agent item's node.
pub fn agent_item(out: &mut String, _depth: usize, i: &AgentItem) {
    match i {
        AgentItem::Operator(h) => out.push_str(&format!("operator: {}", handle(h))),
        AgentItem::Runtime(Runtime::Byo) => out.push_str("runtime: byo"),
        AgentItem::Runtime(Runtime::Hosted) => out.push_str("runtime: hosted"),
    }
}

/// Prints a goal item's node.
pub fn goal_item(out: &mut String, depth: usize, i: &GoalItem) {
    match i {
        GoalItem::Steward(c) => out.push_str(&format!("steward: {}", c.name)),
        GoalItem::Purpose(s) => out.push_str(&format!("purpose {}", string(s))),
        GoalItem::Fund(f) => out.push_str(&format!("fund: {}", fund(f))),
        GoalItem::OnUnderfunded(Underfunded::Pause) => out.push_str("on_underfunded: pause"),
        GoalItem::OnUnderfunded(Underfunded::Continue) => out.push_str("on_underfunded: continue"),
        GoalItem::OnClose(OnClose::ReturnTreasury) => out.push_str("on_close: return treasury"),
        GoalItem::OnClose(OnClose::Transfer(g)) => {
            out.push_str(&format!("on_close: transfer {}", g.name))
        }
        GoalItem::Success(s) => out.push_str(&format!("success: {}", success(s))),
        GoalItem::Mandate(m) => {
            let p = match &m.principal {
                Principal::Agent(a) => a.name.clone(),
                Principal::Person(h) => handle(h),
            };
            out.push_str(&format!("mandate {p} "));
            block(out, depth, &m.body, mandate_item);
        }
        GoalItem::Rule(r) => out.push_str(&rule(r)),
    }
}

/// Prints a mandate item's node.
pub fn mandate_item(out: &mut String, _depth: usize, i: &MandateItem) {
    match i {
        MandateItem::Spend(s) => out.push_str(&format!(
            "spend {} <= {} / {}",
            category(s.category),
            money(&s.limit),
            period(s.period)
        )),
        MandateItem::PerRequest(m) => out.push_str(&format!("per_request <= {}", money(m))),
        MandateItem::Can(cs) => out.push_str(&format!(
            "can: {}",
            cs.iter().map(capability).collect::<Vec<_>>().join(", ")
        )),
        MandateItem::Expires(d) => out.push_str(&format!("expires: {}", d.to_iso())),
    }
}

pub fn rule(r: &Rule) -> String {
    let mut s = format!(
        "rule {} requires {}",
        subject(&r.subject),
        procedure(&r.procedure)
    );
    if let Some(t) = &r.timeout {
        s.push(' ');
        s.push_str(&timeout(t));
    }
    s
}

pub fn string(s: &Str) -> String {
    let mut out = String::from("\"");
    for c in s.value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn handle(h: &Handle) -> String {
    format!("@{}", h.name)
}

pub fn money(m: &Money) -> String {
    format!("usd {}", m.text)
}

pub fn signed(s: &Signed) -> String {
    let mut out = String::new();
    if s.negative {
        out.push('-');
    }
    out.push_str(&s.int);
    if let Some(f) = &s.frac {
        out.push('.');
        out.push_str(f);
    }
    out
}

pub fn duration(d: &Duration) -> String {
    format!("{}{}", d.value, d.unit.as_char())
}

pub fn membership(m: &Membership) -> String {
    match &m.kind {
        MembershipKind::Open => "open()".to_string(),
        MembershipKind::Invite { sponsors } => format!("invite(sponsors: {})", sponsors.value),
    }
}

pub fn group(g: &Group) -> String {
    match g {
        Group::Circle(c) => c.name.clone(),
        Group::Members { .. } => "members".to_string(),
    }
}

pub fn threshold(t: &Threshold) -> String {
    match &t.kind {
        ThresholdKind::Fraction { num, den } => format!("{}/{}", num.value, den.value),
        ThresholdKind::Percent { value } => format!("{}%", value.value),
    }
}

pub fn procedure(p: &Procedure) -> String {
    match &p.kind {
        ProcedureKind::Approve { group: g, count } => {
            format!("approve({}, {})", group(g), count.value)
        }
        ProcedureKind::Vote {
            group: g,
            threshold: t,
        } => format!("vote({}, {})", group(g), threshold(t)),
    }
}

pub fn timeout(t: &Timeout) -> String {
    let outcome = match t.outcome {
        Outcome::Deny => "deny",
        Outcome::Allow => "allow",
    };
    format!("within {} else {outcome}", duration(&t.within))
}

pub fn category(c: Category) -> &'static str {
    match c {
        Category::Llm => "llm",
        Category::Compute => "compute",
        Category::Expense => "expense",
    }
}

pub fn period(p: Period) -> &'static str {
    match p {
        Period::Day => "day",
        Period::Week => "week",
        Period::Month => "month",
    }
}

pub fn fund(f: &Fund) -> String {
    match f.schedule {
        FundSchedule::Every(p) => format!("{} / {} from treasury", money(&f.amount), period(p)),
        FundSchedule::Once => format!("{} once from treasury", money(&f.amount)),
    }
}

pub fn success(s: &Success) -> String {
    let mut out = format!(
        "metric({}) {} {}",
        s.metric.name,
        s.cmp.as_str(),
        signed(&s.value)
    );
    if let Some(d) = &s.by {
        out.push_str(&format!(" by {}", d.to_iso()));
    }
    out
}

pub fn capability(c: &Capability) -> String {
    match &c.kind {
        CapabilityKind::ClaimTasks => "claim_tasks".to_string(),
        CapabilityKind::CreateTasks => "create_tasks".to_string(),
        CapabilityKind::PostEvidence => "post_evidence".to_string(),
        CapabilityKind::ReportMetric(m) => format!("report_metric({})", m.name),
    }
}

pub fn subject(s: &Subject) -> String {
    match &s.kind {
        SubjectKind::Close => "close".to_string(),
        SubjectKind::Spend { category: c, over } => {
            let mut out = String::from("spend");
            if let Some(c) = c {
                out.push(' ');
                out.push_str(category(*c));
            }
            if let Some(m) = over {
                out.push_str(" > ");
                out.push_str(&money(m));
            }
            out
        }
    }
}
