//! Canonical formatter for maru-lang v0 (SPEC-01 §7).
//!
//! The formatter prints the syntax tree, not the source: the output depends only on the
//! AST and its comments, so any two layouts of the same spec format identically and the
//! spec hash ([`source_hash`]) ignores formatting-only edits (SPEC-01 §1).
//!
//! Layout: 2-space indentation, one item per line, lists joined with `, `. One blank line
//! separates a block item (`circle`, `agent`, `goal`, `mandate`) from whatever precedes or
//! follows it inside its block, and a `rule` from a preceding non-rule item; there are no
//! other blank lines. Comments keep their attachment: leading comments on their own lines
//! above the item, a trailing comment after one space, block-end comments before `}`.
//! Trailing whitespace in comments is trimmed. An empty block without comments is `{}`.
//!
//! Numbers: counts and money have their integer part grouped by thousands with `_` when it
//! has 4 or more digits; money fractions lose trailing zeros but keep at least 2 digits.
//! Metric values are grouped the same way and keep their fraction digits as written (the AST
//! keeps them as text; the parser drops leading zeros of the integer part). Durations and
//! dates are never grouped.

use sha2::{Digest, Sha256};

use crate::ast::*;
use crate::diag::{Code, Diagnostic};
use crate::parser::{MAX_SOURCE_BYTES, parse};
use crate::span::{Pos, Span};

/// Formats `src` canonically (SPEC-01 §7). The output parses to the same AST, ignoring
/// spans and comments, and formatting it again returns it unchanged.
///
/// # Errors
///
/// The parse diagnostics when `src` has syntax errors (the parser leaves erroneous items
/// out of the tree, so formatting it would drop them), or a single E109 when the formatted
/// source would exceed [`MAX_SOURCE_BYTES`].
pub fn format(src: &str) -> Result<String, Vec<Diagnostic>> {
    let out = parse(src);
    let file = match out.file {
        Some(file) if !out.diagnostics.iter().any(Diagnostic::is_error) => file,
        _ => return Err(out.diagnostics),
    };
    format_ast(&file).map_err(|d| vec![d])
}

/// Formats a parsed file, or E109 when the result would exceed [`MAX_SOURCE_BYTES`]. The
/// checker uses it to hash the tree it has already parsed.
pub(crate) fn format_ast(file: &File) -> Result<String, Diagnostic> {
    let formatted = format_file(file);
    if formatted.len() > MAX_SOURCE_BYTES {
        let message = format!(
            "formatted source is {} bytes; the maximum is {MAX_SOURCE_BYTES} bytes (256 KiB)",
            formatted.len()
        );
        return Err(Diagnostic::new(
            Code::E109,
            message,
            Span::point(Pos::START),
        ));
    }
    Ok(formatted)
}

/// The spec hash: `"sha256:"` followed by the lowercase hex SHA-256 of [`format`]`(src)`
/// (SPEC-01 §1).
///
/// # Errors
///
/// Whatever [`format`] returns.
pub fn source_hash(src: &str) -> Result<String, Vec<Diagnostic>> {
    Ok(format!("sha256:{}", sha256_hex(&format(src)?)))
}

/// Lowercase hex SHA-256 of `text`.
pub(crate) fn sha256_hex(text: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let digest = Sha256::digest(text.as_bytes());
    let mut out = String::with_capacity(2 * digest.len());
    for byte in digest {
        out.push(char::from(HEX[usize::from(byte >> 4)]));
        out.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    out
}

/// The canonical text of a rule: its formatted line without indentation or comments,
/// e.g. `rule spend > usd 500 requires approve(core, 1) within 48h else deny`. Rule ids
/// hash this text (SPEC-01 §4.6).
pub fn rule_line(rule: &Rule) -> String {
    let subject = match &rule.subject.kind {
        SubjectKind::Close => "close".to_string(),
        SubjectKind::Spend { category, over } => {
            let mut s = "spend".to_string();
            if let Some(c) = category {
                s.push(' ');
                s.push_str(category_str(*c));
            }
            if let Some(m) = over {
                s.push_str(" > ");
                s.push_str(&money(m));
            }
            s
        }
    };
    format!(
        "rule {subject} requires {}{}",
        procedure(&rule.procedure),
        timeout(rule.timeout.as_ref())
    )
}

/// Prints a whole file.
fn format_file(file: &File) -> String {
    let mut p = Printer { out: String::new() };
    p.item(0, &file.org);
    for c in &file.trailing_comments {
        p.comment_line(0, c);
    }
    p.out
}

// ---- layout ----

/// A node that is printed as an item.
trait Node {
    /// Appends the node's text: one line, or a header and a block for block items.
    fn print(&self, p: &mut Printer, depth: usize);

    /// Whether this is a block item (`circle`, `agent`, `goal`, `mandate`).
    fn is_block(&self) -> bool {
        false
    }

    /// Whether this is a `rule`.
    fn is_rule(&self) -> bool {
        false
    }
}

/// Whether a blank line goes between two consecutive items of a block (SPEC-01 §7).
fn blank_between(prev: &impl Node, next: &impl Node) -> bool {
    prev.is_block() || next.is_block() || (next.is_rule() && !prev.is_rule())
}

struct Printer {
    out: String,
}

impl Printer {
    fn indent(&mut self, depth: usize) {
        for _ in 0..depth {
            self.out.push_str("  ");
        }
    }

    fn push(&mut self, s: &str) {
        self.out.push_str(s);
    }

    fn newline(&mut self) {
        self.out.push('\n');
    }

    /// A comment's text without trailing whitespace.
    fn comment(&mut self, c: &Comment) {
        self.out.push_str(c.text.trim_end());
    }

    /// A comment on its own line.
    fn comment_line(&mut self, depth: usize, c: &Comment) {
        self.indent(depth);
        self.comment(c);
        self.newline();
    }

    /// Leading comments, the node, and its trailing comment, ending with a newline.
    fn item<K: Node>(&mut self, depth: usize, it: &Item<K>) {
        for c in &it.leading {
            self.comment_line(depth, c);
        }
        self.indent(depth);
        it.node.print(self, depth);
        if let Some(c) = &it.trailing {
            self.push(" ");
            self.comment(c);
        }
        self.newline();
    }

    /// `{`, the items one per line with the blank-line rules, and `}` (no newline after).
    fn block<K: Node>(&mut self, depth: usize, b: &Block<K>) {
        if b.items.is_empty() && b.open_comment.is_none() && b.end_comments.is_empty() {
            self.push("{}");
            return;
        }
        self.push("{");
        if let Some(c) = &b.open_comment {
            self.push(" ");
            self.comment(c);
        }
        self.newline();
        let mut prev: Option<&K> = None;
        for it in &b.items {
            if prev.is_some_and(|p| blank_between(p, &it.node)) {
                self.newline();
            }
            self.item(depth + 1, it);
            prev = Some(&it.node);
        }
        if !b.end_comments.is_empty() && prev.is_some_and(Node::is_block) {
            self.newline();
        }
        for c in &b.end_comments {
            self.comment_line(depth + 1, c);
        }
        self.indent(depth);
        self.push("}");
    }
}

// ---- items ----

impl Node for Org {
    fn print(&self, p: &mut Printer, depth: usize) {
        p.push("org ");
        p.push(&string(&self.name));
        p.push(" ");
        p.block(depth, &self.body);
    }

    fn is_block(&self) -> bool {
        true
    }
}

impl Node for OrgItem {
    fn print(&self, p: &mut Printer, depth: usize) {
        match self {
            OrgItem::Purpose(s) => p.push(&format!("purpose {}", string(s))),
            OrgItem::Members(m) => p.push(&format!("members: {}", membership(m))),
            OrgItem::Amend(a) => p.push(&format!(
                "amend: {}{}",
                procedure(&a.procedure),
                timeout(a.timeout.as_ref())
            )),
            OrgItem::Circle(c) => {
                p.push(&format!("circle {} ", c.id.name));
                p.block(depth, &c.body);
            }
            OrgItem::Agent(a) => {
                p.push(&format!("agent {} ", a.id.name));
                p.block(depth, &a.body);
            }
            OrgItem::Goal(g) => {
                p.push(&format!("goal {} {} ", g.id.name, string(&g.title)));
                p.block(depth, &g.body);
            }
        }
    }

    fn is_block(&self) -> bool {
        matches!(
            self,
            OrgItem::Circle(_) | OrgItem::Agent(_) | OrgItem::Goal(_)
        )
    }
}

impl Node for CircleItem {
    fn print(&self, p: &mut Printer, _depth: usize) {
        let text = match self {
            CircleItem::Seats(n) => format!("seats: {}", int(n)),
            CircleItem::Term(d) => format!("term: {}", duration(d)),
            CircleItem::Holders(hs) => {
                let hs: Vec<String> = hs.iter().map(handle).collect();
                format!("holders: {}", hs.join(", "))
            }
        };
        p.push(&text);
    }
}

impl Node for AgentItem {
    fn print(&self, p: &mut Printer, _depth: usize) {
        let text = match self {
            AgentItem::Operator(h) => format!("operator: {}", handle(h)),
            AgentItem::Runtime(Runtime::Byo) => "runtime: byo".to_string(),
            AgentItem::Runtime(Runtime::Hosted) => "runtime: hosted".to_string(),
        };
        p.push(&text);
    }
}

impl Node for GoalItem {
    fn print(&self, p: &mut Printer, depth: usize) {
        let text = match self {
            GoalItem::Steward(c) => format!("steward: {}", c.name),
            GoalItem::Purpose(s) => format!("purpose {}", string(s)),
            GoalItem::Fund(f) => {
                let schedule = match f.schedule {
                    FundSchedule::Every(period) => format!("/ {}", period_str(period)),
                    FundSchedule::Once => "once".to_string(),
                };
                format!("fund: {} {schedule} from treasury", money(&f.amount))
            }
            GoalItem::OnUnderfunded(Underfunded::Pause) => "on_underfunded: pause".to_string(),
            GoalItem::OnUnderfunded(Underfunded::Continue) => {
                "on_underfunded: continue".to_string()
            }
            GoalItem::OnClose(OnClose::ReturnTreasury) => "on_close: return treasury".to_string(),
            GoalItem::OnClose(OnClose::Transfer(g)) => format!("on_close: transfer {}", g.name),
            GoalItem::Success(s) => {
                let mut text = format!(
                    "success: metric({}) {} {}",
                    s.metric.name,
                    s.cmp.as_str(),
                    signed(&s.value)
                );
                if let Some(d) = &s.by {
                    text.push_str(" by ");
                    text.push_str(&d.to_iso());
                }
                text
            }
            GoalItem::Mandate(m) => {
                let principal = match &m.principal {
                    Principal::Agent(a) => a.name.clone(),
                    Principal::Person(h) => handle(h),
                };
                p.push(&format!("mandate {principal} "));
                p.block(depth, &m.body);
                return;
            }
            GoalItem::Rule(r) => rule_line(r),
        };
        p.push(&text);
    }

    fn is_block(&self) -> bool {
        matches!(self, GoalItem::Mandate(_))
    }

    fn is_rule(&self) -> bool {
        matches!(self, GoalItem::Rule(_))
    }
}

impl Node for MandateItem {
    fn print(&self, p: &mut Printer, _depth: usize) {
        let text = match self {
            MandateItem::Spend(s) => format!(
                "spend {} <= {} / {}",
                category_str(s.category),
                money(&s.limit),
                period_str(s.period)
            ),
            MandateItem::PerRequest(m) => format!("per_request <= {}", money(m)),
            MandateItem::Can(caps) => {
                let caps: Vec<String> = caps.iter().map(capability).collect();
                format!("can: {}", caps.join(", "))
            }
            MandateItem::Expires(d) => format!("expires: {}", d.to_iso()),
        };
        p.push(&text);
    }
}

// ---- phrases ----

fn membership(m: &Membership) -> String {
    match &m.kind {
        MembershipKind::Open => "open()".to_string(),
        MembershipKind::Invite { sponsors } => format!("invite(sponsors: {})", int(sponsors)),
    }
}

fn procedure(p: &Procedure) -> String {
    let group = |g: &Group| match g {
        Group::Circle(c) => c.name.clone(),
        Group::Members { .. } => "members".to_string(),
    };
    match &p.kind {
        ProcedureKind::Approve { group: g, count } => {
            format!("approve({}, {})", group(g), int(count))
        }
        ProcedureKind::Vote {
            group: g,
            threshold,
        } => {
            let t = match &threshold.kind {
                ThresholdKind::Fraction { num, den } => format!("{}/{}", int(num), int(den)),
                ThresholdKind::Percent { value } => format!("{}%", int(value)),
            };
            format!("vote({}, {t})", group(g))
        }
    }
}

/// ` within <duration> else deny|allow`, with its leading space, or nothing.
fn timeout(t: Option<&Timeout>) -> String {
    match t {
        None => String::new(),
        Some(t) => {
            let outcome = match t.outcome {
                Outcome::Deny => "deny",
                Outcome::Allow => "allow",
            };
            format!(" within {} else {outcome}", duration(&t.within))
        }
    }
}

fn capability(c: &Capability) -> String {
    match &c.kind {
        CapabilityKind::ClaimTasks => "claim_tasks".to_string(),
        CapabilityKind::CreateTasks => "create_tasks".to_string(),
        CapabilityKind::PostEvidence => "post_evidence".to_string(),
        CapabilityKind::ReportMetric(m) => format!("report_metric({})", m.name),
    }
}

const fn category_str(c: Category) -> &'static str {
    match c {
        Category::Llm => "llm",
        Category::Compute => "compute",
        Category::Expense => "expense",
    }
}

const fn period_str(p: Period) -> &'static str {
    match p {
        Period::Day => "day",
        Period::Week => "week",
        Period::Month => "month",
    }
}

// ---- literals ----

/// A string literal with the canonical escapes `\"`, `\\` and `\n`.
fn string(s: &Str) -> String {
    let mut out = String::with_capacity(s.value.len() + 2);
    out.push('"');
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

fn handle(h: &Handle) -> String {
    format!("@{}", h.name)
}

/// `digits` grouped by thousands with `_` iff there are 4 or more (`12000` → `12_000`).
fn group(digits: &str) -> String {
    if digits.len() < 4 {
        return digits.to_string();
    }
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push('_');
        }
        out.push(c);
    }
    out
}

fn int(n: &Int) -> String {
    group(&n.value.to_string())
}

/// `usd X`: the whole part grouped; the fraction without trailing zeros, but with at least
/// 2 digits when there is one (`12.50`, `3.0001`, `7`).
fn money(m: &Money) -> String {
    let whole = group(&(m.micros / 1_000_000).to_string());
    let frac = m.micros % 1_000_000;
    if frac == 0 {
        return format!("usd {whole}");
    }
    let digits = format!("{frac:06}");
    let mut digits = digits.trim_end_matches('0').to_string();
    while digits.len() < 2 {
        digits.push('0');
    }
    format!("usd {whole}.{digits}")
}

/// A metric value: the sign, the integer part grouped, the fraction digits as written.
fn signed(s: &Signed) -> String {
    let mut out = String::new();
    if s.negative {
        out.push('-');
    }
    out.push_str(&group(&s.int));
    if let Some(frac) = &s.frac {
        out.push('.');
        out.push_str(frac);
    }
    out
}

fn duration(d: &Duration) -> String {
    format!("{}{}", d.value, d.unit.as_char())
}

#[cfg(test)]
mod tests {
    use super::group;

    #[test]
    fn groups_by_thousands_from_the_right() {
        assert_eq!(group("1"), "1");
        assert_eq!(group("999"), "999");
        assert_eq!(group("1000"), "1_000");
        assert_eq!(group("123456"), "123_456");
        assert_eq!(group("1234567"), "1_234_567");
        assert_eq!(group("0010000"), "0_010_000");
    }
}
