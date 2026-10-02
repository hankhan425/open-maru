//! Shared helpers for maru_core language tests.
#![allow(dead_code)]

pub mod checking;
#[cfg(feature = "authz")]
pub mod decide_cases;
pub mod ir_strategies;
pub mod printer;
pub mod strategies;

use maru_core::ast::*;
use maru_core::{Code, ParseOutput, Span, parse};
use serde_json::Value;

/// The canonical example spec (copy of `docs/mvp/specs/examples/lumen.maru`).
pub const LUMEN: &str = include_str!("../fixtures/lumen.maru");

/// Removes every `"span"` key, recursively.
pub fn strip_spans(v: &mut Value) {
    match v {
        Value::Object(map) => {
            map.remove("span");
            map.values_mut().for_each(strip_spans);
        }
        Value::Array(items) => items.iter_mut().for_each(strip_spans),
        _ => {}
    }
}

/// The AST as JSON with spans removed, for comparisons that ignore positions.
pub fn ast_json(file: &File) -> Value {
    let mut v = serde_json::to_value(file).expect("AST serializes");
    strip_spans(&mut v);
    v
}

/// The fields of [`File`], [`Item`] and [`Block`] that hold comments.
const TRIVIA_KEYS: &[&str] = &[
    "leading",
    "trailing",
    "open_comment",
    "end_comments",
    "trailing_comments",
];

/// Removes every comment field, recursively.
pub fn strip_trivia(v: &mut Value) {
    match v {
        Value::Object(map) => {
            map.retain(|k, _| !TRIVIA_KEYS.contains(&k.as_str()));
            map.values_mut().for_each(strip_trivia);
        }
        Value::Array(items) => items.iter_mut().for_each(strip_trivia),
        _ => {}
    }
}

/// The AST as JSON without spans or comments: what the formatter must preserve
/// (SPEC-01 §7).
pub fn ast_json_no_trivia(file: &File) -> Value {
    let mut v = ast_json(file);
    strip_trivia(&mut v);
    v
}

/// The AST as JSON without spans and with trailing whitespace trimmed from comment
/// texts, as the formatter trims them.
pub fn ast_json_trimmed_comments(file: &File) -> Value {
    fn trim(v: &mut Value) {
        match v {
            Value::Object(map) => {
                // Only comments have a `text` field.
                if let Some(Value::String(text)) = map.get_mut("text") {
                    *text = text.trim_end().to_string();
                }
                map.values_mut().for_each(trim);
            }
            Value::Array(items) => items.iter_mut().for_each(trim),
            _ => {}
        }
    }
    let mut v = ast_json(file);
    trim(&mut v);
    v
}

/// Asserts the formatter's rules for text (L02-T11): LF line endings, no trailing
/// whitespace, exactly one final newline.
pub fn assert_clean_text(out: &str) {
    assert!(!out.contains("\r\n"), "CRLF in output:\n{out:?}");
    assert!(
        out.ends_with('\n') && !out.ends_with("\n\n"),
        "output must end with exactly one newline:\n{out:?}"
    );
    for line in out.split('\n') {
        assert_eq!(line, line.trim_end(), "trailing whitespace in {out:?}");
    }
}

/// Parses `src`, asserting there are no diagnostics.
pub fn parse_ok(src: &str) -> File {
    let out = parse(src);
    assert!(
        out.diagnostics.is_empty(),
        "unexpected diagnostics for {src:?}: {:#?}",
        out.diagnostics
    );
    out.file.expect("file parsed")
}

/// The diagnostic codes, in order.
pub fn codes(out: &ParseOutput) -> Vec<Code> {
    out.diagnostics.iter().map(|d| d.code).collect()
}

/// Asserts `src` yields exactly one diagnostic with `code` whose span slices to `text`.
pub fn assert_single(src: &str, code: Code, text: &str) {
    let out = parse(src);
    assert_eq!(
        codes(&out),
        vec![code],
        "for {src:?}: {:#?}",
        out.diagnostics
    );
    let span = out.diagnostics[0].span;
    assert_eq!(&src[span.range()], text, "span of {code} in {src:?}");
}

pub fn slice(src: &str, span: Span) -> &str {
    &src[span.range()]
}

/// A minimal valid org with a circle `core` (holder @mina) and an agent `builder`,
/// followed by `extra` org items.
pub fn org_with(extra: &str) -> String {
    format!(
        "org \"T\" {{\n  amend: approve(core, 1)\n  circle core {{\n    seats: 3\n    holders: @mina\n  }}\n  agent builder {{\n    operator: @mina\n  }}\n{extra}\n}}\n"
    )
}

/// [`org_with`] plus a goal `g` stewarded by `core`, followed by `extra` goal items.
pub fn goal_with(extra: &str) -> String {
    org_with(&format!(
        "  goal g \"G\" {{\n    steward: core\n{extra}\n  }}"
    ))
}

/// [`goal_with`] plus a mandate for `builder` containing `extra` mandate items.
pub fn mandate_with(extra: &str) -> String {
    goal_with(&format!("    mandate builder {{\n{extra}\n    }}"))
}

/// [`org_with`] plus a circle `c2` containing `extra` circle items.
pub fn circle_with(extra: &str) -> String {
    org_with(&format!("  circle c2 {{\n{extra}\n  }}"))
}

/// [`org_with`] plus an agent `a2` containing `extra` agent items.
pub fn agent_with(extra: &str) -> String {
    org_with(&format!("  agent a2 {{\n{extra}\n  }}"))
}

pub fn org_items(f: &File) -> Vec<&OrgItem> {
    f.org.node.body.items.iter().map(|i| &i.node).collect()
}

/// The last org item (the one `org_with` appended).
pub fn last_org_item(f: &File) -> &OrgItem {
    &f.org.node.body.items.last().expect("org has items").node
}

pub fn goals(f: &File) -> Vec<&Goal> {
    org_items(f)
        .into_iter()
        .filter_map(|i| match i {
            OrgItem::Goal(g) => Some(g),
            _ => None,
        })
        .collect()
}

/// The goal items of the first goal.
pub fn goal_items(f: &File) -> Vec<&GoalItem> {
    goals(f)[0].body.items.iter().map(|i| &i.node).collect()
}

/// The last goal item of the first goal (the one `goal_with` appended).
pub fn last_goal_item(f: &File) -> &GoalItem {
    goal_items(f).last().copied().expect("goal has items")
}

/// The mandate items of the first mandate of the first goal.
pub fn mandate_items(f: &File) -> Vec<&MandateItem> {
    goal_items(f)
        .into_iter()
        .find_map(|i| match i {
            GoalItem::Mandate(m) => Some(m.body.items.iter().map(|i| &i.node).collect()),
            _ => None,
        })
        .expect("goal has a mandate")
}

pub fn circle(f: &File, id: &str) -> Circle {
    org_items(f)
        .into_iter()
        .find_map(|i| match i {
            OrgItem::Circle(c) if c.id.name == id => Some(c.clone()),
            _ => None,
        })
        .expect("circle exists")
}

pub fn agent(f: &File, id: &str) -> Agent {
    org_items(f)
        .into_iter()
        .find_map(|i| match i {
            OrgItem::Agent(a) if a.id.name == id => Some(a.clone()),
            _ => None,
        })
        .expect("agent exists")
}

/// Every node that carries a span, paired with the naive printer's text for it.
pub fn spanned_nodes(f: &File) -> Vec<(Span, String)> {
    let mut v = Vec::new();
    for c in f.org.leading.iter().chain(&f.trailing_comments) {
        v.push((c.span, c.text.clone()));
    }
    item_nodes(&mut v, &f.org, printer::org, |v, o| {
        v.push((o.name.span, printer::string(&o.name)));
        block_nodes(v, &o.body, printer::org_item, org_item_nodes);
    });
    v
}

type Out = Vec<(Span, String)>;

fn print_node<K>(node: &K, print: fn(&mut String, usize, &K)) -> String {
    let mut s = String::new();
    print(&mut s, 0, node);
    s
}

fn item_nodes<K>(
    v: &mut Out,
    it: &Item<K>,
    print: fn(&mut String, usize, &K),
    inner: fn(&mut Out, &K),
) {
    for c in it.leading.iter().chain(&it.trailing) {
        v.push((c.span, c.text.clone()));
    }
    v.push((it.span, print_node(&it.node, print)));
    inner(v, &it.node);
}

fn block_nodes<K>(
    v: &mut Out,
    b: &Block<K>,
    print: fn(&mut String, usize, &K),
    inner: fn(&mut Out, &K),
) {
    let mut s = String::new();
    printer::block(&mut s, 0, b, print);
    v.push((b.span, s));
    for c in b.open_comment.iter().chain(&b.end_comments) {
        v.push((c.span, c.text.clone()));
    }
    for it in &b.items {
        item_nodes(v, it, print, inner);
    }
}

fn ident(v: &mut Out, i: &Ident) {
    v.push((i.span, i.name.clone()));
}

fn int(v: &mut Out, i: &Int) {
    v.push((i.span, i.value.to_string()));
}

fn money(v: &mut Out, m: &Money) {
    v.push((m.span, printer::money(m)));
}

fn duration(v: &mut Out, d: &Duration) {
    v.push((d.span, printer::duration(d)));
}

fn date(v: &mut Out, d: &Date) {
    v.push((d.span, d.to_iso()));
}

fn procedure(v: &mut Out, p: &Procedure) {
    v.push((p.span, printer::procedure(p)));
    let (ProcedureKind::Approve { group, .. } | ProcedureKind::Vote { group, .. }) = &p.kind;
    match group {
        Group::Circle(c) => ident(v, c),
        Group::Members { span } => v.push((*span, "members".to_string())),
    }
    match &p.kind {
        ProcedureKind::Approve { count, .. } => int(v, count),
        ProcedureKind::Vote { threshold, .. } => {
            v.push((threshold.span, printer::threshold(threshold)));
            match &threshold.kind {
                ThresholdKind::Fraction { num, den } => {
                    int(v, num);
                    int(v, den);
                }
                ThresholdKind::Percent { value } => int(v, value),
            }
        }
    }
}

fn timeout(v: &mut Out, t: &Option<Timeout>) {
    if let Some(t) = t {
        v.push((t.span, printer::timeout(t)));
        duration(v, &t.within);
    }
}

fn org_item_nodes(v: &mut Out, i: &OrgItem) {
    match i {
        OrgItem::Purpose(s) => v.push((s.span, printer::string(s))),
        OrgItem::Members(m) => {
            v.push((m.span, printer::membership(m)));
            if let MembershipKind::Invite { sponsors } = &m.kind {
                int(v, sponsors);
            }
        }
        OrgItem::Amend(a) => {
            procedure(v, &a.procedure);
            timeout(v, &a.timeout);
        }
        OrgItem::Circle(c) => {
            ident(v, &c.id);
            block_nodes(v, &c.body, printer::circle_item, |v, i| match i {
                CircleItem::Seats(n) => int(v, n),
                CircleItem::Term(d) => duration(v, d),
                CircleItem::Holders(hs) => {
                    for h in hs {
                        v.push((h.span, printer::handle(h)));
                    }
                }
            });
        }
        OrgItem::Agent(a) => {
            ident(v, &a.id);
            block_nodes(v, &a.body, printer::agent_item, |v, i| {
                if let AgentItem::Operator(h) = i {
                    v.push((h.span, printer::handle(h)));
                }
            });
        }
        OrgItem::Goal(g) => {
            ident(v, &g.id);
            v.push((g.title.span, printer::string(&g.title)));
            block_nodes(v, &g.body, printer::goal_item, goal_item_nodes);
        }
    }
}

fn goal_item_nodes(v: &mut Out, i: &GoalItem) {
    match i {
        GoalItem::Steward(c) => ident(v, c),
        GoalItem::Purpose(s) => v.push((s.span, printer::string(s))),
        GoalItem::Fund(f) => {
            v.push((f.span, printer::fund(f)));
            money(v, &f.amount);
        }
        GoalItem::OnUnderfunded(_) | GoalItem::OnClose(OnClose::ReturnTreasury) => {}
        GoalItem::OnClose(OnClose::Transfer(g)) => ident(v, g),
        GoalItem::Success(s) => {
            v.push((s.span, printer::success(s)));
            ident(v, &s.metric);
            v.push((s.value.span, printer::signed(&s.value)));
            if let Some(d) = &s.by {
                date(v, d);
            }
        }
        GoalItem::Mandate(m) => {
            match &m.principal {
                Principal::Agent(a) => ident(v, a),
                Principal::Person(h) => v.push((h.span, printer::handle(h))),
            }
            block_nodes(v, &m.body, printer::mandate_item, |v, i| match i {
                MandateItem::Spend(s) => money(v, &s.limit),
                MandateItem::PerRequest(m) => money(v, m),
                MandateItem::Can(cs) => {
                    for c in cs {
                        v.push((c.span, printer::capability(c)));
                        if let CapabilityKind::ReportMetric(m) = &c.kind {
                            ident(v, m);
                        }
                    }
                }
                MandateItem::Expires(d) => date(v, d),
            });
        }
        GoalItem::Rule(r) => {
            v.push((r.subject.span, printer::subject(&r.subject)));
            if let SubjectKind::Spend { over: Some(m), .. } = &r.subject.kind {
                money(v, m);
            }
            procedure(v, &r.procedure);
            timeout(v, &r.timeout);
        }
    }
}
