//! Proptest strategies shared by the language property tests: fuzz inputs (L01-T21,
//! L02 never-panic) and random syntax trees (L01-T22, L02-T09/T10).

use maru_core::ast::*;
use maru_core::lexer::Keyword;
use maru_core::{Pos, Span};
use proptest::prelude::*;

use super::LUMEN;

/// The span given to generated nodes; comparisons strip spans.
pub const NO_SPAN: Span = Span::point(Pos::START);

/// Punctuation and valid/invalid literal fragments for [`token_soup`]. Sampled from a
/// fixed list because regex strategies are slow in debug builds.
pub const FRAGMENTS: &[&str] = &[
    "{",
    "}",
    "(",
    ")",
    ":",
    ",",
    "/",
    "%",
    "-",
    "->",
    "<=",
    ">=",
    "<",
    ">",
    "==",
    "=",
    ".",
    "@",
    "\"",
    "\\",
    "#",
    "\n",
    " ",
    "\r\n",
    "$",
    ";",
    "é",
    "🦀",
    "a",
    "core",
    "x_1",
    "aB",
    "A",
    "_a",
    "_12",
    "0",
    "7",
    "12_000",
    "1_0",
    "12__000",
    "12_",
    "1._5",
    "12.50",
    "1.1234567",
    "99999999999999999999999",
    "30m",
    "7d",
    "0d",
    "7mo",
    "7x",
    "1.5d",
    "2027-06-30",
    "2027-6-30",
    "2027-02-29",
    "10-5",
    "@mina",
    "@a-b_c",
    "@a",
    "@Mina",
    "@-a",
    "\"str\"",
    "\"unterminated",
    "\"a\\nb\"",
    "\"bad\\t\"",
    "\"x\ny\"",
    "# comment\n",
    "#\n",
];

/// Keywords, punctuation and literal fragments glued together at random.
pub fn token_soup() -> impl Strategy<Value = String> {
    let piece = prop_oneof![
        prop::sample::select(Keyword::ALL).prop_map(Keyword::as_str),
        prop::sample::select(FRAGMENTS),
    ];
    prop::collection::vec((piece, prop::sample::select(&["", " ", "\n"][..])), 0..120)
        .prop_map(|parts| parts.into_iter().flat_map(|(p, s)| [p, s]).collect())
}

/// `lumen.maru` with a few random character edits.
pub fn mutated_lumen() -> impl Strategy<Value = String> {
    let edit = (any::<prop::sample::Index>(), 0u8..3, "[\\PC\n{}()\"@#:,]");
    prop::collection::vec(edit, 1..6).prop_map(|edits| {
        let mut chars: Vec<char> = LUMEN.chars().collect();
        for (at, op, s) in edits {
            let i = at.index(chars.len() + 1);
            let c = s.chars().next().unwrap_or(' ');
            match op {
                0 if i < chars.len() => {
                    chars.remove(i);
                }
                1 => chars.insert(i, c),
                _ if i < chars.len() => chars[i] = c,
                _ => {}
            }
        }
        chars.into_iter().collect()
    })
}

// ---- random syntax trees ----

pub fn ident() -> impl Strategy<Value = Ident> {
    prop_oneof![
        8 => "[a-z][a-z0-9_]{0,8}",
        1 => "[a-z][a-z0-9_]{39}",
    ]
    .prop_filter("not a keyword", |s| Keyword::from_word(s).is_none())
    .prop_map(|name| Ident {
        name,
        span: NO_SPAN,
    })
}

pub fn handle() -> impl Strategy<Value = Handle> {
    "[a-z0-9][a-z0-9_-]{1,29}".prop_map(|name| Handle {
        name,
        span: NO_SPAN,
    })
}

pub fn string() -> impl Strategy<Value = Str> {
    "[a-zA-Z0-9 é🦀\"\\\\\n#{}]{0,24}".prop_map(|value| Str {
        value,
        span: NO_SPAN,
    })
}

pub fn int() -> impl Strategy<Value = Int> {
    prop_oneof![0u64..100, 0u64..=MAX_INT].prop_map(|value| Int {
        value,
        span: NO_SPAN,
    })
}

pub fn money() -> impl Strategy<Value = Money> {
    (
        0u64..=9_007_199_253,
        prop_oneof![Just(0u64), 0u64..1_000_000],
    )
        .prop_map(|(whole, frac)| Money {
            micros: whole * 1_000_000 + frac,
            span: NO_SPAN,
        })
}

pub fn signed() -> impl Strategy<Value = Signed> {
    (
        any::<bool>(),
        "[0-9]{1,24}",
        prop::option::of("[0-9]{1,10}"),
    )
        .prop_map(|(negative, int, frac)| Signed {
            negative,
            int,
            frac,
            span: NO_SPAN,
        })
}

pub fn duration() -> impl Strategy<Value = Duration> {
    prop::sample::select(vec![
        DurationUnit::Minutes,
        DurationUnit::Hours,
        DurationUnit::Days,
        DurationUnit::Weeks,
        DurationUnit::Years,
    ])
    .prop_flat_map(|unit| {
        let max = MAX_DURATION_SECS / unit.secs();
        prop_oneof![0u64..=max.min(999), 0u64..=max].prop_map(move |value| Duration {
            value,
            unit,
            span: NO_SPAN,
        })
    })
}

pub fn date() -> impl Strategy<Value = Date> {
    (2000u16..=2999, 1u8..=12, 1u8..=28).prop_map(|(year, month, day)| Date {
        year,
        month,
        day,
        span: NO_SPAN,
    })
}

pub fn comment() -> impl Strategy<Value = Comment> {
    "#[ -~é]{0,16}".prop_map(|text| Comment {
        text,
        span: NO_SPAN,
    })
}

pub fn item<K: std::fmt::Debug + Clone>(
    node: impl Strategy<Value = K>,
) -> impl Strategy<Value = Item<K>> {
    (
        node,
        prop::collection::vec(comment(), 0..2),
        prop::option::weighted(0.2, comment()),
    )
        .prop_map(|(node, leading, trailing)| Item {
            node,
            leading,
            trailing,
            span: NO_SPAN,
        })
}

pub fn block<K: std::fmt::Debug + Clone>(
    node: impl Strategy<Value = K>,
    max: usize,
) -> impl Strategy<Value = Block<K>> {
    (
        prop::collection::vec(item(node), 0..max),
        prop::option::weighted(0.2, comment()),
        prop::collection::vec(comment(), 0..2),
    )
        .prop_map(|(items, open_comment, end_comments)| Block {
            items,
            open_comment,
            end_comments,
            span: NO_SPAN,
        })
}

pub fn group() -> impl Strategy<Value = Group> {
    prop_oneof![
        ident().prop_map(Group::Circle),
        Just(Group::Members { span: NO_SPAN }),
    ]
}

pub fn threshold() -> impl Strategy<Value = Threshold> {
    prop_oneof![
        (int(), int()).prop_map(|(num, den)| ThresholdKind::Fraction { num, den }),
        int().prop_map(|value| ThresholdKind::Percent { value }),
    ]
    .prop_map(|kind| Threshold {
        kind,
        span: NO_SPAN,
    })
}

pub fn procedure() -> impl Strategy<Value = Procedure> {
    prop_oneof![
        (group(), int()).prop_map(|(group, count)| ProcedureKind::Approve { group, count }),
        (group(), threshold())
            .prop_map(|(group, threshold)| ProcedureKind::Vote { group, threshold }),
    ]
    .prop_map(|kind| Procedure {
        kind,
        span: NO_SPAN,
    })
}

pub fn timeout() -> impl Strategy<Value = Option<Timeout>> {
    prop::option::of(
        (duration(), any::<bool>()).prop_map(|(within, deny)| Timeout {
            within,
            outcome: if deny { Outcome::Deny } else { Outcome::Allow },
            span: NO_SPAN,
        }),
    )
}

pub fn category() -> impl Strategy<Value = Category> {
    prop::sample::select(vec![Category::Llm, Category::Compute, Category::Expense])
}

pub fn period() -> impl Strategy<Value = Period> {
    prop::sample::select(vec![Period::Day, Period::Week, Period::Month])
}

pub fn capability() -> impl Strategy<Value = Capability> {
    prop_oneof![
        Just(CapabilityKind::ClaimTasks),
        Just(CapabilityKind::CreateTasks),
        Just(CapabilityKind::PostEvidence),
        ident().prop_map(CapabilityKind::ReportMetric),
    ]
    .prop_map(|kind| Capability {
        kind,
        span: NO_SPAN,
    })
}

pub fn mandate_item() -> impl Strategy<Value = MandateItem> {
    prop_oneof![
        (category(), money(), period()).prop_map(|(category, limit, period)| MandateItem::Spend(
            SpendLimit {
                category,
                limit,
                period
            }
        )),
        money().prop_map(MandateItem::PerRequest),
        prop::collection::vec(capability(), 1..5).prop_map(MandateItem::Can),
        date().prop_map(MandateItem::Expires),
    ]
}

pub fn goal_item() -> impl Strategy<Value = GoalItem> {
    let cmp = prop::sample::select(vec![Cmp::Ge, Cmp::Gt, Cmp::Le, Cmp::Lt, Cmp::Eq]);
    let principal = prop_oneof![
        ident().prop_map(Principal::Agent),
        handle().prop_map(Principal::Person),
    ];
    let subject = prop_oneof![
        Just(SubjectKind::Close),
        (prop::option::of(category()), prop::option::of(money()))
            .prop_map(|(category, over)| SubjectKind::Spend { category, over }),
    ]
    .prop_map(|kind| Subject {
        kind,
        span: NO_SPAN,
    });
    prop_oneof![
        ident().prop_map(GoalItem::Steward),
        string().prop_map(GoalItem::Purpose),
        (money(), prop::option::of(period())).prop_map(|(amount, p)| GoalItem::Fund(Fund {
            amount,
            schedule: p.map_or(FundSchedule::Once, FundSchedule::Every),
            span: NO_SPAN,
        })),
        prop::sample::select(vec![Underfunded::Pause, Underfunded::Continue])
            .prop_map(GoalItem::OnUnderfunded),
        prop_oneof![
            Just(OnClose::ReturnTreasury),
            ident().prop_map(OnClose::Transfer),
        ]
        .prop_map(GoalItem::OnClose),
        (ident(), cmp, signed(), prop::option::of(date())).prop_map(|(metric, cmp, value, by)| {
            GoalItem::Success(Success {
                metric,
                cmp,
                value,
                by,
                span: NO_SPAN,
            })
        }),
        (principal, block(mandate_item(), 5))
            .prop_map(|(principal, body)| GoalItem::Mandate(Mandate { principal, body })),
        (subject, procedure(), timeout()).prop_map(|(subject, procedure, timeout)| GoalItem::Rule(
            Rule {
                subject,
                procedure,
                timeout
            }
        )),
    ]
}

pub fn org_item() -> impl Strategy<Value = OrgItem> {
    let circle_item = prop_oneof![
        int().prop_map(CircleItem::Seats),
        duration().prop_map(CircleItem::Term),
        prop::collection::vec(handle(), 1..4).prop_map(CircleItem::Holders),
    ];
    let agent_item = prop_oneof![
        handle().prop_map(AgentItem::Operator),
        prop::sample::select(vec![Runtime::Byo, Runtime::Hosted]).prop_map(AgentItem::Runtime),
    ];
    let membership = prop_oneof![
        Just(MembershipKind::Open),
        int().prop_map(|sponsors| MembershipKind::Invite { sponsors }),
    ]
    .prop_map(|kind| Membership {
        kind,
        span: NO_SPAN,
    });
    prop_oneof![
        string().prop_map(OrgItem::Purpose),
        membership.prop_map(OrgItem::Members),
        (procedure(), timeout())
            .prop_map(|(procedure, timeout)| OrgItem::Amend(Amend { procedure, timeout })),
        (ident(), block(circle_item, 4))
            .prop_map(|(id, body)| OrgItem::Circle(Circle { id, body })),
        (ident(), block(agent_item, 3)).prop_map(|(id, body)| OrgItem::Agent(Agent { id, body })),
        (ident(), string(), block(goal_item(), 8))
            .prop_map(|(id, title, body)| OrgItem::Goal(Goal { id, title, body })),
    ]
}

pub fn file() -> impl Strategy<Value = File> {
    (
        item((string(), block(org_item(), 7)).prop_map(|(name, body)| Org { name, body })),
        prop::collection::vec(comment(), 0..2),
    )
        .prop_map(|(org, trailing_comments)| File {
            org,
            trailing_comments,
        })
}
