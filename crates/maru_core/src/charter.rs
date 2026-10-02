//! The charter: a deterministic plain-English reading of an [`Ir`] (SPEC-01 §8), as
//! structured [`Section`]s and as Markdown built from them. The golden output for the
//! canonical example is `docs/mvp/specs/examples/lumen.charter.md`.
//!
//! Every string taken from the IR (names, titles, purposes, ids, handles) is written on
//! one line and escaped so that it renders literally: a purpose cannot add a heading or a
//! bullet to the charter (SPEC-01 §8, OQ-12).

use serde::{Deserialize, Serialize};

use crate::human::{count, counted, date, duration, list, money, number, threshold};
use crate::ir::{
    Agent, Amend, Category, Circle, Cmp, Duration, FundPeriod, Goal, Ir, Mandate, Membership,
    OnClose, Outcome, Period, PrincipalKind, Procedure, Rule, Runtime, Subject, Success,
    Underfunded,
};

/// One charter section: a heading and the paragraphs and bullets under it.
///
/// Every string is Markdown inline text: ids are set in `**bold**`, and text taken from
/// the spec is escaped so that it renders literally.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    /// The heading text; `"section"` in JSON (SPEC-01 §8).
    #[serde(rename = "section")]
    pub title: String,
    /// The heading level: 1 for the org, 2 for org-level sections and goals, 3 within a
    /// goal.
    pub level: u8,
    /// Paragraphs, in order. They come before the bullets.
    pub paragraphs: Vec<String>,
    /// Bullet items without their `- ` marker, in order.
    pub bullets: Vec<String>,
}

impl Section {
    fn new(title: String, level: u8, paragraphs: Vec<String>, bullets: Vec<String>) -> Section {
        Section {
            title,
            level,
            paragraphs,
            bullets,
        }
    }
}

/// The charter of `ir` as sections, in the order of SPEC-01 §8: the org, `Membership`,
/// `Changing this charter`, `Circles` and `Agents` (each omitted when empty), then for
/// each goal `Goal: <title>`, `Mandates` and `Rules` (omitted when empty) and `Limits`.
pub fn render_sections(ir: &Ir) -> Vec<Section> {
    let org = &ir.org;
    let mut out = vec![
        Section::new(text(&org.name), 1, purpose(org.purpose.as_deref()), vec![]),
        Section::new(
            "Membership".into(),
            2,
            vec![membership(&org.membership)],
            vec![],
        ),
        Section::new(
            "Changing this charter".into(),
            2,
            vec![amend(&org.amend)],
            vec![],
        ),
    ];
    if !org.circles.is_empty() {
        let bullets = org.circles.iter().map(circle).collect();
        out.push(Section::new("Circles".into(), 2, vec![], bullets));
    }
    if !org.agents.is_empty() {
        let bullets = org.agents.iter().map(agent).collect();
        out.push(Section::new("Agents".into(), 2, vec![], bullets));
    }
    for goal in &org.goals {
        goal_sections(goal, &org.goals, &mut out);
    }
    out
}

/// Markdown for `sections`: each heading, paragraph and bullet list is one block, blocks
/// are separated by a blank line, and the text ends with one newline.
pub fn to_markdown(sections: &[Section]) -> String {
    let mut blocks: Vec<String> = Vec::new();
    for s in sections {
        let hashes = "#".repeat(usize::from(s.level));
        blocks.push(if s.title.is_empty() {
            hashes
        } else {
            format!("{hashes} {}", s.title)
        });
        blocks.extend(s.paragraphs.iter().cloned());
        if !s.bullets.is_empty() {
            let items: Vec<String> = s.bullets.iter().map(|b| format!("- {b}")).collect();
            blocks.push(items.join("\n"));
        }
    }
    let mut md = blocks.join("\n\n");
    md.push('\n');
    md
}

/// The charter of `ir` as Markdown: [`to_markdown`] of [`render_sections`].
pub fn render_markdown(ir: &Ir) -> String {
    to_markdown(&render_sections(ir))
}

// ---- org ----

/// The purpose paragraph, if there is text left once it is on one line.
fn purpose(purpose: Option<&str>) -> Vec<String> {
    purpose
        .map(text)
        .filter(|p| !p.is_empty())
        .into_iter()
        .collect()
}

fn membership(m: &Membership) -> String {
    match m {
        Membership::Open => "Anyone signed in to openmaru can join.".to_string(),
        Membership::Invite { sponsors: 1 } => {
            "New members join when 1 existing member sponsors them.".to_string()
        }
        Membership::Invite { sponsors } => format!(
            "New members join when {} existing members sponsor them.",
            count((*sponsors).into())
        ),
    }
}

fn amend(a: &Amend) -> String {
    let otherwise = match (&a.procedure, a.otherwise) {
        (_, Outcome::Allow) => "If not decided in time, the change is applied.",
        (Procedure::Approve { .. }, Outcome::Deny) => {
            "If not approved in time, the change is rejected."
        }
        (Procedure::Vote { .. }, Outcome::Deny) => {
            "If the vote does not pass in time, the change is rejected."
        }
    };
    format!(
        "Changes need {} within {}. {otherwise}",
        procedure(&a.procedure),
        within(&a.within)
    )
}

fn circle(c: &Circle) -> String {
    let seats = counted(c.seats.into(), "seat", "seats");
    let mut s = match &c.term {
        Some(term) => format!(
            "**{}**: {seats}, each held for {}.",
            text(&c.id),
            within(term)
        ),
        None => format!("**{}**: {seats} with no term limit.", text(&c.id)),
    };
    let holders: Vec<String> = c.holders.iter().map(|h| format!("@{}", text(h))).collect();
    if holders.is_empty() {
        s.push_str(" Holders: none.");
    } else {
        s.push_str(&format!(" Holders: {}.", holders.join(", ")));
    }
    let held = u64::try_from(c.holders.len()).unwrap_or(u64::MAX);
    match u64::from(c.seats).saturating_sub(held) {
        0 => {}
        1 => s.push_str(" 1 seat is vacant."),
        vacant => s.push_str(&format!(" {} seats are vacant.", count(vacant))),
    }
    s
}

fn agent(a: &Agent) -> String {
    let place = match a.runtime {
        Runtime::Hosted => "the hosted runtime",
        Runtime::Byo => "its operator's own infrastructure",
    };
    format!(
        "**{}** is an AI agent operated by @{}, running on {place}.",
        text(&a.id),
        text(&a.operator)
    )
}

// ---- goals ----

fn goal_sections(goal: &Goal, goals: &[Goal], out: &mut Vec<Section>) {
    let mut facts = vec![
        format!("Stewarded by {}.", text(&goal.steward)),
        funding(goal),
        closure(goal, goals),
    ];
    facts.extend(goal.success.as_ref().map(success));
    let title = format!("Goal: {}", text(&goal.title))
        .trim_end()
        .to_string();
    out.push(Section::new(
        title,
        2,
        purpose(goal.purpose.as_deref()),
        facts,
    ));
    if !goal.mandates.is_empty() {
        let bullets = goal.mandates.iter().map(mandate).collect();
        out.push(Section::new("Mandates".into(), 3, vec![], bullets));
    }
    if !goal.rules.is_empty() {
        let bullets = goal.rules.iter().map(rule).collect();
        out.push(Section::new("Rules".into(), 3, vec![], bullets));
    }
    out.push(Section::new("Limits".into(), 3, vec![limits(goal)], vec![]));
}

fn funding(goal: &Goal) -> String {
    let Some(fund) = &goal.fund else {
        return "Is funded only by donations.".to_string();
    };
    let when = match fund.period {
        FundPeriod::Day => "at the start of each day",
        FundPeriod::Week => "at the start of each week (Monday)",
        FundPeriod::Month => "at the start of each month",
        FundPeriod::Once => "once, when this goal is first adopted",
    };
    let short = match goal.on_underfunded {
        Underfunded::Pause => "work on this goal pauses until it is funded.",
        Underfunded::Continue => "work continues with the funds available.",
    };
    format!(
        "Receives {} from the treasury {when}. If the treasury cannot cover it, {short}",
        money(fund.amount_micros)
    )
}

/// Where remaining funds go. A transfer names the receiving goal by its title, or by its
/// id when the IR has no such goal.
fn closure(goal: &Goal, goals: &[Goal]) -> String {
    match &goal.on_close {
        OnClose::ReturnTreasury => {
            "When closed, its remaining funds return to the treasury.".to_string()
        }
        OnClose::Transfer { goal: target } => {
            let name = goals
                .iter()
                .find(|g| &g.id == target)
                .map_or(target, |g| &g.title);
            format!(
                "When closed, its remaining funds move to the goal {}.",
                text(name)
            )
        }
    }
}

fn success(s: &Success) -> String {
    let cmp = match s.cmp {
        Cmp::Ge => "at least",
        Cmp::Gt => "more than",
        Cmp::Le => "at most",
        Cmp::Lt => "less than",
        Cmp::Eq => "exactly",
    };
    let by =
        s.by.as_deref()
            .map(|d| format!(" by {}", text(&date(d))))
            .unwrap_or_default();
    format!(
        "Success means {} reaches {cmp} {}{by}.",
        text(&s.metric),
        text(&number(&s.value))
    )
}

fn mandate(m: &Mandate) -> String {
    let (who, pronoun) = match m.principal.kind {
        PrincipalKind::Agent => (format!("**{}**", text(&m.principal.id)), "It"),
        PrincipalKind::Person => (format!("**@{}**", text(&m.principal.id)), "They"),
    };
    let mut s = if m.spend.is_empty() {
        format!("{who} may not spend funds.")
    } else {
        let limits: Vec<String> = m
            .spend
            .iter()
            .map(|l| {
                format!(
                    "up to {} per {} on {}",
                    money(l.limit_micros),
                    period(l.period),
                    category(l.category)
                )
            })
            .collect();
        let cap = m
            .per_request_micros
            .map(|cap| format!(", at most {} per request", money(cap)))
            .unwrap_or_default();
        format!("{who} may spend {}{cap}.", list(&limits))
    };
    if !m.capabilities.is_empty() {
        let can: Vec<String> = m.capabilities.iter().map(|c| capability(c)).collect();
        s.push_str(&format!(" {pronoun} may {}.", list(&can)));
    }
    if let Some(expires) = &m.expires {
        s.push_str(&format!(
            " This mandate expires on {}.",
            text(&date(expires))
        ));
    }
    s
}

fn capability(c: &str) -> String {
    match c {
        "claim_tasks" => "claim tasks".to_string(),
        "create_tasks" => "create tasks".to_string(),
        "post_evidence" => "post evidence".to_string(),
        _ => match c.strip_prefix("report_metric:") {
            Some(metric) => format!("report {}", text(metric)),
            None => text(c),
        },
    }
}

fn rule(r: &Rule) -> String {
    let (subject, outcome) = match &r.subject {
        Subject::Spend {
            category,
            over_micros,
        } => {
            let any = match category {
                None => "Any spend",
                Some(Category::Llm) => "Any AI-model spend",
                Some(Category::Compute) => "Any compute spend",
                Some(Category::Expense) => "Any expense",
            };
            let subject = match over_micros {
                Some(over) => format!("{any} over {}", money(*over)),
                None => any.to_string(),
            };
            let outcome = match r.otherwise {
                Outcome::Deny => "it is denied",
                Outcome::Allow => "it is allowed",
            };
            (subject, outcome)
        }
        Subject::Close => {
            let outcome = match r.otherwise {
                Outcome::Deny => "it stays open",
                Outcome::Allow => "it is closed",
            };
            ("Closing this goal".to_string(), outcome)
        }
    };
    format!(
        "{subject} needs {} within {}; otherwise {outcome}.",
        procedure(&r.procedure),
        within(&r.within)
    )
}

fn limits(goal: &Goal) -> String {
    if goal.mandates.iter().all(|m| m.spend.is_empty()) {
        return "No one may spend from this goal.".to_string();
    }
    match goal.limits.unapproved_monthly_max_micros {
        0 => "Nothing can be spent on this goal without approval.".to_string(),
        max => format!(
            "Without any approval, at most {} per month can be spent on this goal.",
            money(max)
        ),
    }
}

// ---- shared phrases ----

/// What a decision needs, for `Changes need …` and `… needs …`.
fn procedure(p: &Procedure) -> String {
    match p {
        Procedure::Approve { circle, count } => format!(
            "approval from {} of {}",
            counted((*count).into(), "holder", "holders"),
            text(circle)
        ),
        Procedure::Vote {
            circle: Some(circle),
            threshold: t,
        } => format!(
            "a vote of {}, passing with at least {} of its holders in favour",
            text(circle),
            threshold(t.num, t.den, t.percent)
        ),
        Procedure::Vote {
            circle: None,
            threshold: t,
        } => format!(
            "a vote of all members, passing with at least {} of them in favour",
            threshold(t.num, t.den, t.percent)
        ),
    }
}

fn within(d: &Duration) -> String {
    duration(d.value, d.unit)
}

fn period(p: Period) -> &'static str {
    match p {
        Period::Day => "day",
        Period::Week => "week",
        Period::Month => "month",
    }
}

fn category(c: Category) -> &'static str {
    match c {
        Category::Llm => "AI models",
        Category::Compute => "compute",
        Category::Expense => "expenses",
    }
}

// ---- text from the spec ----

/// Spec text as Markdown inline text that renders literally (SPEC-01 §8, OQ-12): on one
/// line (each run of whitespace becomes one space, ends trimmed), with a backslash before
/// every character that could start inline syntax, open a block at the start of a
/// paragraph, or close a heading.
fn text(s: &str) -> String {
    let chars: Vec<char> = one_line(s).chars().collect();
    let n = chars.len();
    // The first `#` of a heading's closing sequence: `#`s at the end, after a space.
    let hashes = chars.iter().rev().take_while(|&&c| c == '#').count();
    let closing = (hashes > 0 && (hashes == n || chars.get(n - hashes - 1) == Some(&' ')))
        .then_some(n - hashes);
    // The `.` or `)` of an ordered list marker at the start (`1. `).
    let digits = chars.iter().take_while(|c| c.is_ascii_digit()).count();
    let list_marker = ((1..=9).contains(&digits)
        && matches!(chars.get(digits), Some('.' | ')'))
        && matches!(chars.get(digits + 1), None | Some(' ')))
    .then_some(digits);

    let mut out = String::with_capacity(s.len() + 8);
    for (i, &c) in chars.iter().enumerate() {
        let prev = i.checked_sub(1).and_then(|j| chars.get(j)).copied();
        let next = chars.get(i + 1).copied();
        let escape = match c {
            '\\' | '`' | '*' | '[' | ']' | '~' => true,
            '_' => {
                !(prev.is_some_and(char::is_alphanumeric)
                    && next.is_some_and(char::is_alphanumeric))
            }
            '<' => next.is_some_and(|c| c.is_ascii_alphabetic() || matches!(c, '/' | '!' | '?')),
            '&' => starts_reference(chars.get(i + 1..).unwrap_or_default()),
            '#' => i == 0 || Some(i) == closing,
            '>' => i == 0,
            '-' => i == 0 && matches!(next, None | Some(' ' | '-')),
            '+' => i == 0 && matches!(next, None | Some(' ')),
            '.' | ')' => Some(i) == list_marker,
            _ => false,
        };
        if escape {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// `s` with each run of Markdown whitespace (space, tab, line breaks, form feed) replaced
/// by one space and the ends trimmed.
fn one_line(s: &str) -> String {
    let words: Vec<&str> = s
        .split([' ', '\t', '\n', '\r', '\u{b}', '\u{c}'])
        .filter(|w| !w.is_empty())
        .collect();
    words.join(" ")
}

/// Whether the characters after a `&` complete an entity or character reference
/// (`amp;`, `#35;`, `#x23;`), which Markdown would turn into another character.
fn starts_reference(rest: &[char]) -> bool {
    let run = |chars: &[char], ok: fn(&char) -> bool| chars.iter().take_while(|c| ok(c)).count();
    match rest {
        ['#', 'x' | 'X', hex @ ..] => {
            let k = run(hex, char::is_ascii_hexdigit);
            (1..=6).contains(&k) && hex.get(k) == Some(&';')
        }
        ['#', dec @ ..] => {
            let k = run(dec, char::is_ascii_digit);
            (1..=7).contains(&k) && dec.get(k) == Some(&';')
        }
        [first, ..] if first.is_ascii_alphabetic() => {
            let k = run(rest, char::is_ascii_alphanumeric);
            rest.get(k) == Some(&';')
        }
        _ => false,
    }
}
