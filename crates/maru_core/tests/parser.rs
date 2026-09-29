//! L01 parser tests: lumen, comments, recovery, CRLF, size limit, every production, spans.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::ast::*;
use maru_core::parser::MAX_SOURCE_BYTES;
use maru_core::{Code, Diagnostic, Pos, Span, parse};
use support::*;

/// A snippet and a check on the node it parses to.
type Case<T> = (&'static str, fn(&T) -> bool);

// L01-T01
#[test]
fn l01_t01_lumen_parses_without_diagnostics() {
    let f = parse_ok(LUMEN);
    insta::assert_json_snapshot!("lumen_ast", ast_json(&f));
}

// L01-T11
#[test]
fn l01_t11_leading_comments_attach_to_the_next_item() {
    let src = "# about the org\norg \"T\" {\n  # first\n  # second\n  amend: approve(core, 1)\n\n  # circle comment\n  circle core {\n    # seats comment\n    seats: 1\n  }\n}\n";
    let f = parse_ok(src);
    let texts = |cs: &[Comment]| cs.iter().map(|c| c.text.clone()).collect::<Vec<_>>();
    assert_eq!(texts(&f.org.leading), ["# about the org"]);
    let items = &f.org.node.body.items;
    assert_eq!(texts(&items[0].leading), ["# first", "# second"]);
    assert_eq!(texts(&items[1].leading), ["# circle comment"]);
    let c = circle(&f, "core");
    assert_eq!(texts(&c.body.items[0].leading), ["# seats comment"]);
    for c in f.org.leading.iter().chain(&items[0].leading) {
        assert_eq!(slice(src, c.span), c.text);
    }
}

// L01-T11
#[test]
fn l01_t11_trailing_comments_attach_to_the_item_on_the_same_line() {
    let src = "org \"T\" { # org open\n  amend: approve(core, 1) # amend trailing\n  # circle leading\n  circle core { # circle open\n    seats: 1 # seats trailing\n  } # circle trailing\n} # org trailing\n# after org\n";
    let f = parse_ok(src);
    let text = |c: &Option<Comment>| c.as_ref().map(|c| c.text.clone());
    let items = &f.org.node.body.items;
    assert_eq!(
        text(&f.org.node.body.open_comment).as_deref(),
        Some("# org open")
    );
    assert_eq!(
        text(&items[0].trailing).as_deref(),
        Some("# amend trailing")
    );
    assert!(items[0].leading.is_empty());
    assert_eq!(items[1].leading[0].text, "# circle leading");
    assert_eq!(
        text(&items[1].trailing).as_deref(),
        Some("# circle trailing")
    );
    let c = circle(&f, "core");
    assert_eq!(text(&c.body.open_comment).as_deref(), Some("# circle open"));
    assert_eq!(
        text(&c.body.items[0].trailing).as_deref(),
        Some("# seats trailing")
    );
    assert_eq!(text(&f.org.trailing).as_deref(), Some("# org trailing"));
    assert_eq!(f.trailing_comments[0].text, "# after org");
}

// L01-T11
#[test]
fn l01_t11_comment_before_closing_brace_attaches_to_block_end() {
    let src = "org \"T\" {\n  amend: approve(core, 1)\n  circle core {\n    seats: 1\n    # end of circle\n  }\n  # end of org\n}\n";
    let f = parse_ok(src);
    let c = circle(&f, "core");
    assert_eq!(c.body.end_comments[0].text, "# end of circle");
    assert!(c.body.items[0].trailing.is_none());
    assert_eq!(f.org.node.body.end_comments[0].text, "# end of org");
    // An empty block keeps its comment too.
    let f = parse_ok(&goal_with("    mandate @jo {\n      # nothing yet\n    }"));
    let GoalItem::Mandate(m) = last_goal_item(&f) else {
        panic!("expected mandate");
    };
    assert!(m.body.items.is_empty());
    assert_eq!(m.body.end_comments[0].text, "# nothing yet");
}

// L01-T14
#[test]
fn l01_t14_missing_closing_brace_is_e202_at_eof() {
    let src = "org \"T\" {\n  amend: approve(core, 1)\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E202], "{:#?}", out.diagnostics);
    let eof = Pos {
        line: 3,
        col: 1,
        offset: src.len(),
    };
    assert_eq!(out.diagnostics[0].span, Span::point(eof));
    // Everything before EOF is still in the tree.
    assert_eq!(out.file.expect("file").org.node.body.items.len(), 1);

    // A nested block left open at EOF: still exactly one E202.
    let src = "org \"T\" {\n  amend: approve(core, 1)\n  circle core {\n    seats: 1";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E202], "{:#?}", out.diagnostics);
    assert_eq!(out.diagnostics[0].span.start.offset, src.len());
    assert_eq!(out.diagnostics[0].span.start.line, 4);
}

// L01-T15
#[test]
fn l01_t15_content_after_org_block_is_e203() {
    let src = "org \"A\" {} org \"B\" {}";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E203], "{:#?}", out.diagnostics);
    let span = out.diagnostics[0].span;
    assert_eq!(
        span.start,
        Pos {
            line: 1,
            col: 12,
            offset: 11
        }
    );
    assert_eq!(slice(src, span), "org");
    // The first org is kept.
    assert_eq!(out.file.expect("file").org.node.name.value, "A");
}

// L01-T16
#[test]
fn l01_t16_two_errors_in_two_goals_give_two_diagnostics() {
    let src = org_with(concat!(
        "  goal a \"A\" {\n",
        "    steward: core\n",
        "    fund: usd 5 / fortnight from treasury\n",
        "    on_underfunded: pause\n",
        "  }\n",
        "  goal b \"B\" {\n",
        "    steward: core\n",
        "    on_close: return\n",
        "    success: metric(wau) >= 10\n",
        "  }",
    ));
    let out = parse(&src);
    assert_eq!(out.diagnostics.len(), 2, "{:#?}", out.diagnostics);
    assert!(out.diagnostics.iter().all(|d| d.code == Code::E201));
    assert_eq!(slice(&src, out.diagnostics[0].span), "fortnight");
    assert_eq!(slice(&src, out.diagnostics[1].span), "success");
    // Both goals survive, each without its broken item.
    let f = out.file.expect("file");
    let gs = goals(&f);
    assert_eq!(gs.len(), 2);
    assert_eq!(gs[0].body.items.len(), 2);
    assert_eq!(gs[1].body.items.len(), 2);
}

// L01-T17
#[test]
fn l01_t17_unknown_goal_item_is_one_e201_and_parsing_continues() {
    let src = goal_with("    budget: 5\n    mandate @jo {\n      can: claim_tasks\n    }");
    let out = parse(&src);
    assert_eq!(codes(&out), vec![Code::E201], "{:#?}", out.diagnostics);
    let d = &out.diagnostics[0];
    assert_eq!(slice(&src, d.span), "budget");
    for item in [
        "steward",
        "purpose",
        "fund",
        "on_underfunded",
        "on_close",
        "success",
        "mandate",
        "rule",
    ] {
        assert!(
            d.message.contains(&format!("`{item}`")),
            "message lists `{item}`: {}",
            d.message
        );
    }
    let f = out.file.expect("file");
    assert!(matches!(
        last_goal_item(&f),
        GoalItem::Mandate(Mandate { principal: Principal::Person(h), .. }) if h.name == "jo"
    ));
}

// L01-T18
#[test]
fn l01_t18_crlf_input_parses_to_the_same_ast() {
    let crlf = LUMEN.replace('\n', "\r\n");
    assert_eq!(ast_json(&parse_ok(&crlf)), ast_json(&parse_ok(LUMEN)));
}

// L01-T19
#[test]
fn l01_t19_source_over_256_kib_is_a_single_e109() {
    let mut src = LUMEN.to_string();
    src.push_str("$ \"unterminated");
    while src.len() <= MAX_SOURCE_BYTES {
        src.push_str("# padding padding padding padding\n");
    }
    let out = parse(&src);
    assert_eq!(codes(&out), vec![Code::E109], "{:?}", codes(&out));
    assert!(out.file.is_none());
}

// L01-T20
#[test]
fn l01_t20_org_level_productions() {
    let cases: &[Case<OrgItem>] = &[
        (
            "purpose \"p\"",
            |i| matches!(i, OrgItem::Purpose(s) if s.value == "p"),
        ),
        ("members: open()", |i| {
            matches!(
                i,
                OrgItem::Members(Membership {
                    kind: MembershipKind::Open,
                    ..
                })
            )
        }),
        (
            "members: invite(sponsors: 2)",
            |i| matches!(i, OrgItem::Members(Membership { kind: MembershipKind::Invite { sponsors }, .. }) if sponsors.value == 2),
        ),
        (
            "amend: approve(core, 2)",
            |i| matches!(i, OrgItem::Amend(Amend { procedure: Procedure { kind: ProcedureKind::Approve { group: Group::Circle(c), count }, .. }, timeout: None }) if c.name == "core" && count.value == 2),
        ),
        ("amend: vote(core, 2/3) within 7d else deny", |i| {
            matches!(
                i,
                OrgItem::Amend(Amend {
                    procedure: Procedure {
                        kind: ProcedureKind::Vote {
                            group: Group::Circle(_),
                            ..
                        },
                        ..
                    },
                    timeout: Some(Timeout {
                        outcome: Outcome::Deny,
                        ..
                    })
                })
            )
        }),
        ("amend: vote(members, 1/2) within 30m else allow", |i| {
            matches!(
                i,
                OrgItem::Amend(Amend {
                    procedure: Procedure {
                        kind: ProcedureKind::Vote {
                            group: Group::Members { .. },
                            ..
                        },
                        ..
                    },
                    timeout: Some(Timeout {
                        outcome: Outcome::Allow,
                        within: Duration {
                            value: 30,
                            unit: DurationUnit::Minutes,
                            ..
                        },
                        ..
                    })
                })
            )
        }),
        ("amend: approve(members, 1)", |i| {
            matches!(
                i,
                OrgItem::Amend(Amend {
                    procedure: Procedure {
                        kind: ProcedureKind::Approve {
                            group: Group::Members { .. },
                            ..
                        },
                        ..
                    },
                    ..
                })
            )
        }),
        (
            "circle c2 {\n    seats: 1\n  }",
            |i| matches!(i, OrgItem::Circle(c) if c.id.name == "c2"),
        ),
        (
            "agent a2 {\n    operator: @jo\n  }",
            |i| matches!(i, OrgItem::Agent(a) if a.id.name == "a2"),
        ),
        (
            "goal g2 \"Title\" {\n    steward: core\n  }",
            |i| matches!(i, OrgItem::Goal(g) if g.id.name == "g2" && g.title.value == "Title"),
        ),
    ];
    for (snippet, check) in cases {
        let f = parse_ok(&org_with(&format!("  {snippet}")));
        let item = last_org_item(&f);
        assert!(check(item), "{snippet} parsed to {item:#?}");
    }
}

// L01-T20
#[test]
fn l01_t20_circle_and_agent_productions() {
    let circle_cases: &[Case<CircleItem>] = &[
        (
            "seats: 3",
            |i| matches!(i, CircleItem::Seats(n) if n.value == 3),
        ),
        ("term: 1y", |i| {
            matches!(
                i,
                CircleItem::Term(Duration {
                    value: 1,
                    unit: DurationUnit::Years,
                    ..
                })
            )
        }),
        (
            "holders: @a1, @b2",
            |i| matches!(i, CircleItem::Holders(hs) if hs.iter().map(|h| h.name.as_str()).eq(["a1", "b2"])),
        ),
        (
            "holders: @solo",
            |i| matches!(i, CircleItem::Holders(hs) if hs.len() == 1),
        ),
    ];
    for (snippet, check) in circle_cases {
        let f = parse_ok(&circle_with(&format!("    {snippet}")));
        let item = &circle(&f, "c2").body.items[0].node;
        assert!(check(item), "{snippet} parsed to {item:#?}");
    }
    let agent_cases: &[Case<AgentItem>] = &[
        (
            "operator: @jo",
            |i| matches!(i, AgentItem::Operator(h) if h.name == "jo"),
        ),
        ("runtime: byo", |i| {
            matches!(i, AgentItem::Runtime(Runtime::Byo))
        }),
        ("runtime: hosted", |i| {
            matches!(i, AgentItem::Runtime(Runtime::Hosted))
        }),
    ];
    for (snippet, check) in agent_cases {
        let f = parse_ok(&agent_with(&format!("    {snippet}")));
        let item = &agent(&f, "a2").body.items[0].node;
        assert!(check(item), "{snippet} parsed to {item:#?}");
    }
}

fn success_is(
    i: &GoalItem,
    cmp: Cmp,
    negative: bool,
    int: &str,
    frac: Option<&str>,
    by: bool,
) -> bool {
    matches!(i, GoalItem::Success(s)
        if s.metric.name == "wau"
            && s.cmp == cmp
            && s.value.negative == negative
            && s.value.int == int
            && s.value.frac.as_deref() == frac
            && s.by.is_some() == by)
}

// L01-T20
#[test]
fn l01_t20_goal_productions() {
    let cases: &[Case<GoalItem>] = &[
        (
            "steward: core",
            |i| matches!(i, GoalItem::Steward(c) if c.name == "core"),
        ),
        (
            "purpose \"why\"",
            |i| matches!(i, GoalItem::Purpose(s) if s.value == "why"),
        ),
        (
            "fund: usd 5 / month from treasury",
            |i| matches!(i, GoalItem::Fund(Fund { amount, schedule: FundSchedule::Every(Period::Month), .. }) if amount.micros == 5_000_000),
        ),
        ("fund: usd 5 / week from treasury", |i| {
            matches!(
                i,
                GoalItem::Fund(Fund {
                    schedule: FundSchedule::Every(Period::Week),
                    ..
                })
            )
        }),
        ("fund: usd 5 / day from treasury", |i| {
            matches!(
                i,
                GoalItem::Fund(Fund {
                    schedule: FundSchedule::Every(Period::Day),
                    ..
                })
            )
        }),
        (
            "fund: usd 250.5 once from treasury",
            |i| matches!(i, GoalItem::Fund(Fund { amount, schedule: FundSchedule::Once, .. }) if amount.micros == 250_500_000),
        ),
        ("on_underfunded: pause", |i| {
            matches!(i, GoalItem::OnUnderfunded(Underfunded::Pause))
        }),
        ("on_underfunded: continue", |i| {
            matches!(i, GoalItem::OnUnderfunded(Underfunded::Continue))
        }),
        ("on_close: return treasury", |i| {
            matches!(i, GoalItem::OnClose(OnClose::ReturnTreasury))
        }),
        (
            "on_close: transfer other",
            |i| matches!(i, GoalItem::OnClose(OnClose::Transfer(g)) if g.name == "other"),
        ),
        ("success: metric(wau) >= 10_000 by 2027-06-30", |i| {
            success_is(i, Cmp::Ge, false, "10000", None, true)
        }),
        ("success: metric(wau) >= 10", |i| {
            success_is(i, Cmp::Ge, false, "10", None, false)
        }),
        ("success: metric(wau) > 10", |i| {
            success_is(i, Cmp::Gt, false, "10", None, false)
        }),
        ("success: metric(wau) <= 10", |i| {
            success_is(i, Cmp::Le, false, "10", None, false)
        }),
        ("success: metric(wau) < 10", |i| {
            success_is(i, Cmp::Lt, false, "10", None, false)
        }),
        ("success: metric(wau) == 10", |i| {
            success_is(i, Cmp::Eq, false, "10", None, false)
        }),
        ("success: metric(wau) >= -5", |i| {
            success_is(i, Cmp::Ge, true, "5", None, false)
        }),
        ("success: metric(wau) <= 2.50", |i| {
            success_is(i, Cmp::Le, false, "2", Some("50"), false)
        }),
        ("success: metric(wau) > -1_500.25 by 2028-02-29", |i| {
            success_is(i, Cmp::Gt, true, "1500", Some("25"), true)
        }),
        (
            "mandate builder {\n    }",
            |i| matches!(i, GoalItem::Mandate(Mandate { principal: Principal::Agent(a), .. }) if a.name == "builder"),
        ),
        (
            "mandate @jo {\n      can: claim_tasks\n    }",
            |i| matches!(i, GoalItem::Mandate(Mandate { principal: Principal::Person(h), body }) if h.name == "jo" && body.items.len() == 1),
        ),
    ];
    for (snippet, check) in cases {
        let f = parse_ok(&goal_with(&format!("    {snippet}")));
        let item = last_goal_item(&f);
        assert!(check(item), "{snippet} parsed to {item:#?}");
    }
}

// L01-T20
#[test]
fn l01_t20_mandate_productions() {
    let cases: &[Case<MandateItem>] = &[
        (
            "spend llm <= usd 4_000 / month",
            |i| matches!(i, MandateItem::Spend(SpendLimit { category: Category::Llm, limit, period: Period::Month }) if limit.micros == 4_000_000_000),
        ),
        ("spend compute <= usd 1 / week", |i| {
            matches!(
                i,
                MandateItem::Spend(SpendLimit {
                    category: Category::Compute,
                    period: Period::Week,
                    ..
                })
            )
        }),
        ("spend expense <= usd 1 / day", |i| {
            matches!(
                i,
                MandateItem::Spend(SpendLimit {
                    category: Category::Expense,
                    period: Period::Day,
                    ..
                })
            )
        }),
        (
            "per_request <= usd 25",
            |i| matches!(i, MandateItem::PerRequest(m) if m.micros == 25_000_000),
        ),
        (
            "can: claim_tasks",
            |i| matches!(i, MandateItem::Can(cs) if matches!(cs[..], [Capability { kind: CapabilityKind::ClaimTasks, .. }])),
        ),
        (
            "can: create_tasks",
            |i| matches!(i, MandateItem::Can(cs) if matches!(cs[..], [Capability { kind: CapabilityKind::CreateTasks, .. }])),
        ),
        (
            "can: post_evidence",
            |i| matches!(i, MandateItem::Can(cs) if matches!(cs[..], [Capability { kind: CapabilityKind::PostEvidence, .. }])),
        ),
        (
            "can: report_metric(wau)",
            |i| matches!(i, MandateItem::Can(cs) if matches!(&cs[..], [Capability { kind: CapabilityKind::ReportMetric(m), .. }] if m.name == "wau")),
        ),
        (
            "can: claim_tasks, create_tasks, post_evidence, report_metric(x)",
            |i| matches!(i, MandateItem::Can(cs) if cs.len() == 4),
        ),
        (
            "expires: 2027-01-01",
            |i| matches!(i, MandateItem::Expires(d) if d.to_iso() == "2027-01-01"),
        ),
    ];
    for (snippet, check) in cases {
        let f = parse_ok(&mandate_with(&format!("      {snippet}")));
        let item = mandate_items(&f)[0];
        assert!(check(item), "{snippet} parsed to {item:#?}");
    }
}

fn rule_of(src: &str) -> Rule {
    match last_goal_item(&parse_ok(src)) {
        GoalItem::Rule(r) => r.clone(),
        other => panic!("expected rule, got {other:#?}"),
    }
}

// L01-T20
#[test]
fn l01_t20_rule_subjects() {
    let cases: &[(&str, Option<Category>, Option<u64>)] = &[
        ("spend", None, None),
        ("spend llm", Some(Category::Llm), None),
        ("spend compute", Some(Category::Compute), None),
        ("spend > usd 5", None, Some(5_000_000)),
        (
            "spend expense > usd 5",
            Some(Category::Expense),
            Some(5_000_000),
        ),
    ];
    for (subject, category, over) in cases {
        let r = rule_of(&goal_with(&format!(
            "    rule {subject} requires approve(core, 1)"
        )));
        let SubjectKind::Spend {
            category: c,
            over: o,
        } = &r.subject.kind
        else {
            panic!("{subject}: expected spend subject");
        };
        assert_eq!(c, category, "{subject}");
        assert_eq!(o.as_ref().map(|m| m.micros), *over, "{subject}");
    }
    let r = rule_of(&goal_with("    rule close requires approve(core, 1)"));
    assert_eq!(r.subject.kind, SubjectKind::Close);
}

// L01-T20
#[test]
fn l01_t20_procedures_and_timeouts() {
    let r = rule_of(&goal_with("    rule close requires approve(core, 1)"));
    assert!(
        matches!(r.procedure.kind, ProcedureKind::Approve { group: Group::Circle(ref c), ref count } if c.name == "core" && count.value == 1)
    );
    assert!(r.timeout.is_none());

    let r = rule_of(&goal_with(
        "    rule close requires vote(core, 2/3) within 48h else deny",
    ));
    assert!(matches!(
        r.procedure.kind,
        ProcedureKind::Vote {
            group: Group::Circle(_),
            ..
        }
    ));
    let t = r.timeout.expect("timeout");
    assert_eq!(
        (t.within.value, t.within.unit, t.outcome),
        (48, DurationUnit::Hours, Outcome::Deny)
    );

    let r = rule_of(&goal_with(
        "    rule spend requires vote(members, 60%) within 2w else allow",
    ));
    assert!(matches!(
        r.procedure.kind,
        ProcedureKind::Vote {
            group: Group::Members { .. },
            ..
        }
    ));
    assert_eq!(r.timeout.expect("timeout").outcome, Outcome::Allow);
}

// L01-T23
#[test]
fn l01_t23_every_lumen_node_span_slices_its_text() {
    let f = parse_ok(LUMEN);
    let nodes = spanned_nodes(&f);
    assert!(nodes.len() > 80, "walked {} nodes", nodes.len());
    // Compare without whitespace and without digit-group `_` (the printer emits numbers
    // from their values, e.g. `10000` for `10_000`).
    let squash = |s: &str| {
        let chars: Vec<char> = s.split_whitespace().collect::<String>().chars().collect();
        (0..chars.len())
            .filter(|&i| {
                let digit = |j: Option<usize>| {
                    j.and_then(|j| chars.get(j))
                        .is_some_and(char::is_ascii_digit)
                };
                !(chars[i] == '_' && digit(i.checked_sub(1)) && digit(Some(i + 1)))
            })
            .map(|i| chars[i])
            .collect::<String>()
    };
    for (span, printed) in nodes {
        let text = slice(LUMEN, span);
        assert!(!text.is_empty(), "empty span for {printed:?}");
        assert_eq!(
            text.trim(),
            text,
            "span has surrounding whitespace: {text:?}"
        );
        assert_eq!(squash(text), squash(&printed), "span {span:?}");
        // line/col agree with the byte offset.
        let before = &LUMEN[..span.start.offset];
        assert_eq!(span.start.line as usize, before.matches('\n').count() + 1);
        let line_start = before.rfind('\n').map_or(0, |i| i + 1);
        assert_eq!(
            span.start.col as usize,
            LUMEN[line_start..span.start.offset].chars().count() + 1
        );
    }
}

// L01 extra: the fixture is an exact copy of the canonical example.
#[test]
fn l01_fixture_matches_docs_example() {
    assert_eq!(
        LUMEN,
        include_str!("../../../docs/mvp/specs/examples/lumen.maru")
    );
}

// L01 extra: diagnostics serialize exactly in the SPEC-01 §5 shape.
#[test]
fn l01_diagnostic_serializes_in_spec_shape() {
    let d = Diagnostic::new(
        Code::E302,
        "unknown circle `cor`",
        Span::new(
            Pos {
                line: 14,
                col: 14,
                offset: 301,
            },
            Pos {
                line: 14,
                col: 17,
                offset: 304,
            },
        ),
    )
    .with_note("did you mean `core`?");
    assert_eq!(
        serde_json::to_string(&d).expect("serializes"),
        r#"{"code":"E302","severity":"error","message":"unknown circle `cor`","span":{"start":{"line":14,"col":14,"offset":301},"end":{"line":14,"col":17,"offset":304}},"notes":["did you mean `core`?"]}"#
    );
    assert_eq!(Code::W408.severity(), maru_core::Severity::Warning);
    let back: Diagnostic =
        serde_json::from_str(&serde_json::to_string(&d).expect("json")).expect("parses");
    assert_eq!(back, d);
}

// L01 extra: exactly 256 KiB is still parsed.
#[test]
fn l01_source_of_exactly_256_kib_is_parsed() {
    let mut src = LUMEN.to_string();
    while src.len() + 40 <= MAX_SOURCE_BYTES {
        src.push_str("# padding padding padding padding pad\n");
    }
    src.push('#');
    while src.len() < MAX_SOURCE_BYTES {
        src.push('x');
    }
    assert_eq!(src.len(), MAX_SOURCE_BYTES);
    parse_ok(&src);
}

// L01 extra: empty or header-less sources.
#[test]
fn l01_empty_source_is_e202_and_junk_is_e201() {
    let out = parse("");
    assert_eq!(codes(&out), vec![Code::E202]);
    assert!(out.file.is_none());
    let out = parse("   # only a comment\n");
    assert_eq!(codes(&out), vec![Code::E202]);
    let out = parse("circle core {}");
    assert_eq!(codes(&out), vec![Code::E201], "{:#?}", out.diagnostics);
    assert!(out.file.is_none());
}

// L01 extra: a block missing its `}` before an item of the enclosing block is one E201,
// and the enclosing item is still parsed.
#[test]
fn l01_unclosed_mandate_before_rule_is_one_diagnostic() {
    let src = goal_with(
        "    mandate @jo {\n      can: claim_tasks\n    rule close requires approve(core, 1)",
    );
    let out = parse(&src);
    assert_eq!(codes(&out), vec![Code::E201], "{:#?}", out.diagnostics);
    assert_eq!(slice(&src, out.diagnostics[0].span), "rule");
    let f = out.file.expect("file");
    assert!(matches!(last_goal_item(&f), GoalItem::Rule(_)));
}

// L01 extra: money above 2^53 − 1 micros cannot be represented (E310).
#[test]
fn l01_money_above_maximum_is_e310() {
    let f = parse_ok(&mandate_with(
        "      per_request <= usd 9_007_199_254.740991",
    ));
    assert!(
        matches!(mandate_items(&f)[0], MandateItem::PerRequest(m) if m.micros == MAX_MONEY_MICROS)
    );
    for n in ["9_007_199_254.740992", "99999999999999999999999999999999"] {
        assert_single(
            &mandate_with(&format!("      per_request <= usd {n}")),
            Code::E310,
            n,
        );
    }
}

// L01 extra: unknown escapes are E101 at the escape.
#[test]
fn l01_unknown_string_escape_is_e101() {
    assert_single(&org_with(r#"  purpose "tab\there""#), Code::E101, r"\t");
}

// L01 extra: positions in CRLF sources count one line per CRLF.
#[test]
fn l01_crlf_positions() {
    let src = "org \"T\" {\r\n  amend: approve(core, 1)\r\n  purpose $\r\n}\r\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E101]);
    let start = out.diagnostics[0].span.start;
    assert_eq!((start.line, start.col), (3, 11));
    assert_eq!(slice(src, out.diagnostics[0].span), "$");
}

// L01 extra: comments written inside an item are kept with it.
#[test]
fn l01_comment_inside_an_item_is_kept_as_leading() {
    let f = parse_ok(&goal_with(
        "    rule spend # inner\n      requires approve(core, 1)",
    ));
    let items = &goals(&f)[0].body.items;
    assert_eq!(items.last().expect("rule").leading[0].text, "# inner");
}

// L01 extra: integers too large for u64 are malformed numbers.
#[test]
fn l01_integer_overflow_is_e103() {
    let n = "99999999999999999999999";
    assert_single(&circle_with(&format!("    seats: {n}")), Code::E103, n);
    // …but a metric value keeps its digits.
    let f = parse_ok(&goal_with(&format!("    success: metric(wau) >= {n}")));
    assert!(matches!(last_goal_item(&f), GoalItem::Success(s) if s.value.int == n));
}

// L01 extra: diagnostics are sorted by position.
#[test]
fn l01_diagnostics_are_sorted_by_position() {
    let src = org_with("  purpose \"a\" $\n  circle Bad {\n    seats: 1\n  }\n  purpose ;");
    let out = parse(&src);
    let offsets: Vec<usize> = out
        .diagnostics
        .iter()
        .map(|d| d.span.start.offset)
        .collect();
    let mut sorted = offsets.clone();
    sorted.sort_unstable();
    assert_eq!(offsets, sorted);
    assert_eq!(codes(&out), vec![Code::E101, Code::E107, Code::E101]);
}
