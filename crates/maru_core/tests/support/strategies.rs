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
        // The parser drops leading zeros from the integer part (OQ-9).
        "0|[1-9][0-9]{0,23}",
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

// ---- plausible specs (L03-T30) ----
//
// Specs built from small pools of names, so that references usually resolve and a good
// share of specs check clean, while each kind of mistake still comes up now and then:
// near-miss references (`cor`, `buildr`, `g3`), zero amounts and durations, maximal amounts,
// repeated ids, holders and fields, and missing required fields.

const HANDLES: &[&str] = &["mina", "jo", "sam"];

fn ident_of(name: &str) -> Ident {
    Ident {
        name: name.to_string(),
        span: NO_SPAN,
    }
}

/// `name` most of the time, `typo` rarely.
fn reference(name: &'static str, typo: &'static str) -> impl Strategy<Value = Ident> {
    prop_oneof![30 => Just(name), 1 => Just(typo)].prop_map(ident_of)
}

/// A reference to `core` (declared in every plausible spec), sometimes `ops` (declared
/// only in some), rarely the near miss `cor`.
fn circle_ref() -> impl Strategy<Value = Ident> {
    prop_oneof![30 => Just("core"), 3 => Just("ops"), 1 => Just("cor")].prop_map(ident_of)
}

fn pool_handle() -> impl Strategy<Value = Handle> {
    prop::sample::select(HANDLES).prop_map(|name| Handle {
        name: name.to_string(),
        span: NO_SPAN,
    })
}

/// A count in `low..=high`, rarely `0`.
fn count_int(low: u64, high: u64) -> impl Strategy<Value = Int> {
    prop_oneof![30 => low..=high, 1 => Just(0u64)].prop_map(|value| Int {
        value,
        span: NO_SPAN,
    })
}

fn plausible_money() -> impl Strategy<Value = Money> {
    prop_oneof![
        40 => prop::sample::select(vec![
            1_000_000u64,
            25_000_000,
            500_000_000,
            4_000_000_000,
            12_000_000_000,
        ]),
        1 => Just(0u64),
        1 => Just(MAX_MONEY_MICROS),
    ]
    .prop_map(|micros| Money {
        micros,
        span: NO_SPAN,
    })
}

fn plausible_duration() -> impl Strategy<Value = Duration> {
    let unit = prop::sample::select(vec![
        DurationUnit::Hours,
        DurationUnit::Days,
        DurationUnit::Years,
    ]);
    (prop_oneof![40 => 1u64..=48, 1 => Just(0u64)], unit).prop_map(|(value, unit)| Duration {
        value,
        unit,
        span: NO_SPAN,
    })
}

fn plausible_procedure() -> BoxedStrategy<Procedure> {
    // `approve(members, …)` is E322, so it is rarer than `vote(members, …)`.
    let approve_group = prop_oneof![
        30 => circle_ref().prop_map(Group::Circle),
        1 => Just(Group::Members { span: NO_SPAN }),
    ];
    let vote_group = prop_oneof![
        6 => circle_ref().prop_map(Group::Circle),
        1 => Just(Group::Members { span: NO_SPAN }),
    ];
    let approvals =
        prop_oneof![20 => Just(1u64), 4 => Just(2u64), 1 => Just(0u64)].prop_map(|value| Int {
            value,
            span: NO_SPAN,
        });
    let fraction = (1u64..=4)
        .prop_flat_map(|den| (count_int(1, den), Just(den)))
        .prop_map(|(num, den)| ThresholdKind::Fraction {
            num,
            den: Int {
                value: den,
                span: NO_SPAN,
            },
        });
    let percent =
        prop_oneof![30 => 1u64..=100, 1 => Just(101u64), 1 => Just(0u64)].prop_map(|value| {
            ThresholdKind::Percent {
                value: Int {
                    value,
                    span: NO_SPAN,
                },
            }
        });
    let threshold = prop_oneof![fraction, percent].prop_map(|kind| Threshold {
        kind,
        span: NO_SPAN,
    });
    prop_oneof![
        (approve_group, approvals)
            .prop_map(|(group, count)| ProcedureKind::Approve { group, count }),
        (vote_group, threshold)
            .prop_map(|(group, threshold)| ProcedureKind::Vote { group, threshold }),
    ]
    .prop_map(|kind| Procedure {
        kind,
        span: NO_SPAN,
    })
    .boxed()
}

fn plausible_timeout() -> BoxedStrategy<Option<Timeout>> {
    prop::option::of((plausible_duration(), prop::bool::weighted(0.9)).prop_map(
        |(within, deny)| Timeout {
            within,
            outcome: if deny { Outcome::Deny } else { Outcome::Allow },
            span: NO_SPAN,
        },
    ))
    .boxed()
}

/// Wraps nodes as items without comments.
fn bare<K>(nodes: Vec<K>) -> Block<K> {
    Block {
        items: nodes
            .into_iter()
            .map(|node| Item {
                node,
                leading: Vec::new(),
                trailing: None,
                span: NO_SPAN,
            })
            .collect(),
        open_comment: None,
        end_comments: Vec::new(),
        span: NO_SPAN,
    }
}

/// The present `items`, then rarely a copy of one of them (E301, E305, E313, …).
fn with_rare_dup<K: Clone>(items: Vec<Option<K>>, dup: Option<prop::sample::Index>) -> Vec<K> {
    let mut items: Vec<K> = items.into_iter().flatten().collect();
    if let Some(i) = dup {
        if !items.is_empty() {
            let copy = items[i.index(items.len())].clone();
            items.push(copy);
        }
    }
    items
}

fn rare_dup() -> impl Strategy<Value = Option<prop::sample::Index>> {
    prop::option::weighted(0.03, any::<prop::sample::Index>())
}

/// Rarely `None`, so a required field goes missing (E304).
fn required<T: std::fmt::Debug>(s: impl Strategy<Value = T>) -> impl Strategy<Value = Option<T>> {
    prop::option::weighted(0.97, s)
}

/// A circle with 2–4 seats and distinct holders (rarely none, too many, or repeated).
fn plausible_circle(id: &'static str) -> BoxedStrategy<OrgItem> {
    let holders = prop_oneof![
        30 => prop::sample::subsequence(HANDLES, 1..=2),
        1 => Just(Vec::new()),
        1 => prop::sample::subsequence(HANDLES, 3..=3),
        1 => Just(vec!["mina", "mina"]),
    ]
    .prop_map(|names| {
        CircleItem::Holders(
            names
                .into_iter()
                .map(|name| Handle {
                    name: name.to_string(),
                    span: NO_SPAN,
                })
                .collect(),
        )
    });
    (
        required(count_int(2, 4).prop_map(CircleItem::Seats)),
        holders.prop_map(|h| match &h {
            CircleItem::Holders(names) if names.is_empty() => None,
            _ => Some(h),
        }),
        prop::option::weighted(0.3, plausible_duration().prop_map(CircleItem::Term)),
        rare_dup(),
    )
        .prop_map(move |(seats, holders, term, dup)| {
            OrgItem::Circle(Circle {
                id: ident_of(id),
                body: bare(with_rare_dup(vec![seats, holders, term], dup)),
            })
        })
        .boxed()
}

fn plausible_agent(id: &'static str) -> BoxedStrategy<OrgItem> {
    let runtime =
        prop::sample::select(vec![Runtime::Byo, Runtime::Hosted]).prop_map(AgentItem::Runtime);
    (
        required(pool_handle().prop_map(AgentItem::Operator)),
        prop::option::of(runtime),
        rare_dup(),
    )
        .prop_map(move |(operator, runtime, dup)| {
            OrgItem::Agent(Agent {
                id: ident_of(id),
                body: bare(with_rare_dup(vec![operator, runtime], dup)),
            })
        })
        .boxed()
}

fn plausible_mandate(principal: Principal) -> BoxedStrategy<GoalItem> {
    let spend = (category(), plausible_money(), period()).prop_map(|(category, limit, period)| {
        MandateItem::Spend(SpendLimit {
            category,
            limit,
            period,
        })
    });
    let capability = prop_oneof![
        Just(CapabilityKind::ClaimTasks),
        Just(CapabilityKind::CreateTasks),
        Just(CapabilityKind::PostEvidence),
        Just(CapabilityKind::ReportMetric(ident_of("users"))),
    ]
    .prop_map(|kind| Capability {
        kind,
        span: NO_SPAN,
    });
    (
        prop::sample::subsequence(
            vec![Category::Llm, Category::Compute, Category::Expense],
            0..=3,
        ),
        prop::collection::vec(spend, 3),
        prop::option::weighted(0.3, plausible_money().prop_map(MandateItem::PerRequest)),
        prop::option::weighted(
            0.5,
            prop::collection::vec(capability, 1..4).prop_map(MandateItem::Can),
        ),
        prop::option::weighted(0.3, date().prop_map(MandateItem::Expires)),
        rare_dup(),
    )
        .prop_map(move |(categories, lines, per_request, can, expires, dup)| {
            // One line per chosen category (E313 only through the rare duplicate).
            let spend = categories
                .into_iter()
                .zip(lines)
                .map(|(category, line)| match line {
                    MandateItem::Spend(s) => Some(MandateItem::Spend(SpendLimit { category, ..s })),
                    other => Some(other),
                });
            let items = spend.chain([per_request, can, expires]).collect();
            GoalItem::Mandate(Mandate {
                principal: principal.clone(),
                body: bare(with_rare_dup(items, dup)),
            })
        })
        .boxed()
}

fn plausible_rule(subject: SubjectKind) -> BoxedStrategy<GoalItem> {
    (plausible_procedure(), plausible_timeout())
        .prop_map(move |(procedure, timeout)| {
            GoalItem::Rule(Rule {
                subject: Subject {
                    kind: subject.clone(),
                    span: NO_SPAN,
                },
                procedure,
                timeout,
            })
        })
        .boxed()
}

/// The mandates of a goal: distinct principals from the declared agents (rarely the near
/// miss `buildr`; `scout` is declared only sometimes) and people; rarely a repeated
/// principal (E312).
fn plausible_mandates() -> BoxedStrategy<Vec<GoalItem>> {
    let principals = vec![
        Principal::Agent(ident_of("builder")),
        Principal::Person(Handle {
            name: "jo".to_string(),
            span: NO_SPAN,
        }),
        Principal::Person(Handle {
            name: "kim".to_string(),
            span: NO_SPAN,
        }),
    ];
    (
        prop::sample::subsequence(principals, 0..=3),
        prop_oneof![
            24 => Just(None),
            4 => Just(Some(Principal::Agent(ident_of("scout")))),
            1 => Just(Some(Principal::Agent(ident_of("buildr")))),
        ],
        rare_dup(),
    )
        .prop_flat_map(|(mut principals, typo, dup)| {
            principals.extend(typo);
            if let (Some(i), false) = (dup, principals.is_empty()) {
                principals.push(principals[i.index(principals.len())].clone());
            }
            principals
                .into_iter()
                .map(plausible_mandate)
                .collect::<Vec<_>>()
        })
        .boxed()
}

/// The rules of a goal: distinct subjects, rarely a repeated one (E314).
fn plausible_rules() -> BoxedStrategy<Vec<GoalItem>> {
    let subjects = vec![
        SubjectKind::Close,
        SubjectKind::Spend {
            category: None,
            over: Some(Money {
                micros: 500_000_000,
                span: NO_SPAN,
            }),
        },
        SubjectKind::Spend {
            category: Some(Category::Llm),
            over: None,
        },
        SubjectKind::Spend {
            category: Some(Category::Expense),
            over: None,
        },
        SubjectKind::Spend {
            category: None,
            over: None,
        },
    ];
    (prop::sample::subsequence(subjects, 0..=3), rare_dup())
        .prop_flat_map(|(mut subjects, dup)| {
            if let (Some(i), false) = (dup, subjects.is_empty()) {
                subjects.push(subjects[i.index(subjects.len())].clone());
            }
            subjects.into_iter().map(plausible_rule).collect::<Vec<_>>()
        })
        .boxed()
}

fn plausible_goal(id: &'static str, other: &'static str) -> BoxedStrategy<OrgItem> {
    let fund = (plausible_money(), prop::option::of(period())).prop_map(|(amount, p)| {
        GoalItem::Fund(Fund {
            amount: Money {
                // Large funds, so that W403 stays occasional.
                micros: amount.micros.saturating_mul(10).min(MAX_MONEY_MICROS),
                span: NO_SPAN,
            },
            schedule: p.map_or(FundSchedule::Once, FundSchedule::Every),
            span: NO_SPAN,
        })
    });
    let on_close = prop_oneof![
        Just(OnClose::ReturnTreasury),
        reference(other, "g3").prop_map(OnClose::Transfer),
    ]
    .prop_map(GoalItem::OnClose);
    let success = (signed(), prop::option::of(date())).prop_map(|(value, by)| {
        GoalItem::Success(Success {
            metric: ident_of("users"),
            cmp: Cmp::Ge,
            value,
            by,
            span: NO_SPAN,
        })
    });
    let underfunded = prop::sample::select(vec![Underfunded::Pause, Underfunded::Continue])
        .prop_map(GoalItem::OnUnderfunded);
    (
        string(),
        required(circle_ref().prop_map(GoalItem::Steward)),
        prop::option::weighted(0.6, fund),
        prop::option::weighted(0.3, underfunded),
        prop::option::weighted(0.3, on_close),
        prop::option::weighted(0.3, success),
        plausible_mandates(),
        plausible_rules(),
        rare_dup(),
    )
        .prop_map(
            move |(title, steward, fund, underfunded, on_close, success, mandates, rules, dup)| {
                let fields = vec![steward, fund, underfunded, on_close, success];
                let mut items = with_rare_dup(fields, dup);
                items.extend(mandates);
                items.extend(rules);
                OrgItem::Goal(Goal {
                    id: ident_of(id),
                    title,
                    body: bare(items),
                })
            },
        )
        .boxed()
}

/// A spec built from small name pools, often valid and sometimes not (L03-T30). It
/// always declares circle `core` and goal `g1`; `ops`, agents `builder` and `scout`, and
/// goal `g2` come and go.
pub fn plausible_file() -> impl Strategy<Value = File> {
    let membership = prop_oneof![
        Just(MembershipKind::Open),
        count_int(1, 3).prop_map(|sponsors| MembershipKind::Invite { sponsors }),
    ]
    .prop_map(|kind| {
        OrgItem::Members(Membership {
            kind,
            span: NO_SPAN,
        })
    });
    let amend = (plausible_procedure(), plausible_timeout())
        .prop_map(|(procedure, timeout)| OrgItem::Amend(Amend { procedure, timeout }));
    (
        string(),
        prop::option::weighted(0.3, membership),
        required(amend),
        (
            plausible_circle("core"),
            prop::option::of(plausible_circle("ops")),
        ),
        (
            prop::option::weighted(0.9, plausible_agent("builder")),
            prop::option::weighted(0.3, plausible_agent("scout")),
        ),
        (
            plausible_goal("g1", "g2"),
            prop::option::of(plausible_goal("g2", "g1")),
        ),
        rare_dup(),
    )
        .prop_map(
            |(name, membership, amend, (core, ops), (builder, scout), (g1, g2), dup)| {
                let items = vec![
                    membership,
                    amend,
                    Some(core),
                    ops,
                    builder,
                    scout,
                    Some(g1),
                    g2,
                ];
                File {
                    org: Item {
                        node: Org {
                            name,
                            body: bare(with_rare_dup(items, dup)),
                        },
                        leading: Vec::new(),
                        trailing: None,
                        span: NO_SPAN,
                    },
                    trailing_comments: Vec::new(),
                }
            },
        )
}
