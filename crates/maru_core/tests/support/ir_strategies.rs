//! Proptest strategies for whole IR values (L04 charter properties). They build the IR
//! directly, not through the checker, so they also reach values the checker never emits
//! (text with Markdown and line breaks, holders beyond seats, unknown transfer targets,
//! malformed dates): the charter must render any IR that deserializes.

use maru_core::ast::MAX_MONEY_MICROS;
use maru_core::ir::*;
use proptest::prelude::*;

/// Pieces of free text: words, whitespace, Markdown syntax and non-ASCII.
pub const TEXT_PIECES: &[&str] = &[
    "Lumen",
    "editor",
    " ",
    "  ",
    "\t",
    "\n",
    "\n\n",
    "#",
    "## Rules",
    "-",
    "- ",
    "+ ",
    "* ",
    "1. ",
    "2)",
    "> ",
    "---",
    "***",
    "___",
    "===",
    "*a*",
    "_a_",
    "a_b",
    "`x`",
    "```",
    "~~x~~",
    "[x](y)",
    "![i](j)",
    "<b>",
    "</p>",
    "<!-- c -->",
    "&amp;",
    "&#35;",
    "R&D",
    "\\",
    "|",
    "$",
    "é",
    "🦀",
    "    code",
    ".",
    ",",
];

pub const IDS: &[&str] = &[
    "core",
    "ops",
    "builder",
    "weekly_active_users",
    "a_",
    "x__y",
];
pub const HANDLES: &[&str] = &["mina", "jo", "a-_b", "z9"];
pub const DATES: &[&str] = &[
    "2027-06-30",
    "2027-01-01",
    "2000-02-29",
    "2027-02-30",
    "soon",
];
pub const METRIC_VALUES: &[&str] = &["0", "10000", "-0.5", "1234567.891", "12.50", "x"];

pub fn text() -> impl Strategy<Value = String> {
    prop::collection::vec(prop::sample::select(TEXT_PIECES), 0..6).prop_map(|v| v.concat())
}

fn id() -> impl Strategy<Value = String> {
    prop::sample::select(IDS).prop_map(str::to_string)
}

fn handle() -> impl Strategy<Value = String> {
    prop::sample::select(HANDLES).prop_map(str::to_string)
}

fn date() -> impl Strategy<Value = String> {
    prop::sample::select(DATES).prop_map(str::to_string)
}

fn count() -> impl Strategy<Value = u32> {
    prop_oneof![10 => 1u32..=5, 1 => Just(0u32), 1 => any::<u32>()]
}

fn money() -> impl Strategy<Value = u64> {
    prop_oneof![
        10 => prop::sample::select(vec![1u64, 125, 500_000, 12_500_000, 4_000_000_000]),
        1 => 1..=MAX_MONEY_MICROS,
    ]
}

fn duration() -> impl Strategy<Value = Duration> {
    let unit = prop::sample::select(vec![
        (DurationUnit::Minutes, 60u64),
        (DurationUnit::Hours, 3_600),
        (DurationUnit::Days, 86_400),
        (DurationUnit::Weeks, 604_800),
        (DurationUnit::Years, 31_536_000),
    ]);
    (prop_oneof![5 => 1u64..=3, 1 => 1u64..=36_500], unit).prop_map(|(value, (unit, secs))| {
        Duration {
            value,
            unit,
            secs: value * secs,
        }
    })
}

fn outcome() -> impl Strategy<Value = Outcome> {
    prop_oneof![Just(Outcome::Deny), Just(Outcome::Allow)]
}

fn threshold() -> impl Strategy<Value = Threshold> {
    prop_oneof![
        (1u32..=4, 1u32..=5).prop_map(|(num, den)| Threshold {
            num,
            den,
            percent: false
        }),
        (1u32..=100).prop_map(|num| Threshold {
            num,
            den: 100,
            percent: true
        }),
    ]
}

fn procedure() -> impl Strategy<Value = Procedure> {
    prop_oneof![
        (id(), count()).prop_map(|(circle, count)| Procedure::Approve { circle, count }),
        (prop::option::of(id()), threshold())
            .prop_map(|(circle, threshold)| Procedure::Vote { circle, threshold }),
    ]
}

fn category() -> impl Strategy<Value = Category> {
    prop_oneof![
        Just(Category::Llm),
        Just(Category::Compute),
        Just(Category::Expense)
    ]
}

fn period() -> impl Strategy<Value = Period> {
    prop_oneof![Just(Period::Day), Just(Period::Week), Just(Period::Month)]
}

fn circle() -> impl Strategy<Value = Circle> {
    (
        id(),
        count(),
        prop::option::of(duration()),
        prop::collection::vec(handle(), 0..4),
    )
        .prop_map(|(id, seats, term, holders)| Circle {
            id,
            seats,
            term,
            holders,
        })
}

fn agent() -> impl Strategy<Value = Agent> {
    (
        id(),
        handle(),
        prop_oneof![Just(Runtime::Byo), Just(Runtime::Hosted)],
    )
        .prop_map(|(id, operator, runtime)| Agent {
            id,
            operator,
            runtime,
        })
}

fn capability() -> impl Strategy<Value = String> {
    prop::sample::select(vec![
        "claim_tasks",
        "create_tasks",
        "post_evidence",
        "report_metric:weekly_active_users",
        "report_metric:m",
    ])
    .prop_map(str::to_string)
}

fn mandate() -> impl Strategy<Value = Mandate> {
    let principal = prop_oneof![
        id().prop_map(|id| Principal {
            kind: PrincipalKind::Agent,
            id
        }),
        handle().prop_map(|id| Principal {
            kind: PrincipalKind::Person,
            id
        }),
    ];
    let spend =
        (category(), money(), period()).prop_map(|(category, limit_micros, period)| SpendLimit {
            category,
            limit_micros,
            period,
        });
    (
        principal,
        prop::collection::vec(spend, 0..4),
        prop::option::of(money()),
        prop::collection::vec(capability(), 0..4),
        prop::option::of(date()),
    )
        .prop_map(
            |(principal, spend, per_request_micros, capabilities, expires)| Mandate {
                principal,
                spend,
                per_request_micros,
                capabilities,
                expires,
            },
        )
}

fn rule() -> impl Strategy<Value = Rule> {
    let subject = prop_oneof![
        3 => (prop::option::of(category()), prop::option::of(money()))
            .prop_map(|(category, over_micros)| Subject::Spend { category, over_micros }),
        1 => Just(Subject::Close),
    ];
    (subject, procedure(), duration(), outcome()).prop_map(
        |(subject, procedure, within, otherwise)| Rule {
            id: "g:r_00000000".to_string(),
            subject,
            procedure,
            within,
            otherwise,
        },
    )
}

fn goal() -> impl Strategy<Value = Goal> {
    let fund = (
        money(),
        prop::sample::select(vec![
            FundPeriod::Day,
            FundPeriod::Week,
            FundPeriod::Month,
            FundPeriod::Once,
        ]),
    )
        .prop_map(|(amount_micros, period)| Fund {
            amount_micros,
            period,
        });
    let on_close = prop_oneof![
        Just(OnClose::ReturnTreasury),
        id().prop_map(|goal| OnClose::Transfer { goal }),
    ];
    let cmp = prop::sample::select(vec![Cmp::Ge, Cmp::Gt, Cmp::Le, Cmp::Lt, Cmp::Eq]);
    let success = (
        id(),
        cmp,
        prop::sample::select(METRIC_VALUES),
        prop::option::of(date()),
    )
        .prop_map(|(metric, cmp, value, by)| Success {
            metric,
            cmp,
            value: value.to_string(),
            by,
        });
    (
        (id(), text(), prop::option::of(text()), id()),
        (
            prop::option::of(fund),
            prop_oneof![Just(Underfunded::Pause), Just(Underfunded::Continue)],
            on_close,
            prop::option::of(success),
        ),
        prop::collection::vec(mandate(), 0..3),
        prop::collection::vec(rule(), 0..4),
        prop_oneof![Just(0u64), money()],
    )
        .prop_map(
            |(
                (id, title, purpose, steward),
                (fund, on_underfunded, on_close, success),
                mandates,
                rules,
                max,
            )| Goal {
                id,
                title,
                purpose,
                steward,
                fund,
                on_underfunded,
                on_close,
                success,
                mandates,
                rules,
                limits: Limits {
                    unapproved_monthly_max_micros: max,
                },
            },
        )
        .boxed()
}

/// An arbitrary IR: every variant of every field, in small numbers.
pub fn ir() -> impl Strategy<Value = Ir> {
    let membership = prop_oneof![
        Just(Membership::Open),
        count().prop_map(|sponsors| Membership::Invite { sponsors }),
    ];
    let amend =
        (procedure(), duration(), outcome()).prop_map(|(procedure, within, otherwise)| Amend {
            procedure,
            within,
            otherwise,
        });
    (
        (text(), prop::option::of(text()), membership, amend),
        prop::collection::vec(circle(), 0..3),
        prop::collection::vec(agent(), 0..3),
        prop::collection::vec(goal(), 0..3),
    )
        .prop_map(
            |((name, purpose, membership, amend), circles, agents, goals)| Ir {
                ir_version: IR_VERSION,
                source_hash: "sha256:0".to_string(),
                org: Org {
                    name,
                    purpose,
                    membership,
                    amend,
                    circles,
                    agents,
                    goals,
                },
            },
        )
}
