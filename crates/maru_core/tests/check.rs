//! L03 checker tests: diagnostics E3xx/W4xx, the IR (defaults, rule ids, thresholds,
//! durations), limits analysis, determinism and the IR JSON Schema. Every check goes
//! through `support::checking::run`, which validates each IR against `schema/ir.v1.json`
//! (L03-T29).
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::ast::MAX_MONEY_MICROS;
use maru_core::parser::MAX_SOURCE_BYTES;
use maru_core::{CheckOptions, Code, Ir, check};
use serde_json::{Value, json};
use support::LUMEN;
use support::checking::*;

const GOLDEN: &str = include_str!("snapshots/lumen.ir.json");

/// Lumen's goal as JSON.
fn lumen_goal(src: &str) -> Value {
    ir_json(src)["org"]["goals"][0].clone()
}

/// The `unapproved_monthly_max_micros` of goal `g` in a clean source.
fn monthly_max(src: &str) -> u64 {
    let ir = ir_ok(src);
    ir.org.goals[0].limits.unapproved_monthly_max_micros
}

/// `lumen.maru` with `from` replaced by `to` (which must occur exactly once).
fn lumen_with(from: &str, to: &str) -> String {
    assert_eq!(LUMEN.matches(from).count(), 1, "{from:?} in lumen");
    LUMEN.replace(from, to)
}

// ---- golden and defaults ----

// L03-T01
#[test]
fn l03_t01_lumen_checks_clean_and_matches_the_golden_ir() {
    let out = run(LUMEN);
    assert!(out.diagnostics.is_empty(), "{:#?}", out.diagnostics);
    let ir = out.ir.expect("IR");
    let actual = serde_json::to_value(&ir).unwrap();
    let golden: Value = serde_json::from_str(GOLDEN).unwrap();
    assert_eq!(actual, golden);
    assert_eq!(
        actual["org"]["goals"][0]["limits"]["unapproved_monthly_max_micros"],
        json!(5_000_000_000u64)
    );
    // Byte-identical when pretty-printed, and the golden deserializes to the same IR.
    assert_eq!(serde_json::to_string_pretty(&ir).unwrap() + "\n", GOLDEN);
    assert_eq!(serde_json::from_str::<Ir>(GOLDEN).unwrap(), ir);
}

// L03-T02
#[test]
fn l03_t02_minimal_org_materializes_defaults() {
    let src = "org \"Min\" {
  amend: approve(core, 1)

  circle core {
    seats: 1
    holders: @mina
  }

  agent bot {
    operator: @mina
  }

  goal g \"G\" {
    steward: core

    mandate bot {
      can: claim_tasks
    }

    rule close requires approve(core, 1)
  }
}
";
    let ir = ir_json(src);
    let d7 = json!({"value": 7, "unit": "d", "secs": 604800});
    let expected = json!({
        "name": "Min",
        "purpose": null,
        "membership": {"kind": "invite", "sponsors": 1},
        "amend": {
            "procedure": {"kind": "approve", "circle": "core", "count": 1},
            "within": d7,
            "else": "deny"
        },
        "circles": [{"id": "core", "seats": 1, "term": null, "holders": ["mina"]}],
        "agents": [{"id": "bot", "operator": "mina", "runtime": "byo"}],
        "goals": [{
            "id": "g",
            "title": "G",
            "purpose": null,
            "steward": "core",
            "fund": null,
            "on_underfunded": "pause",
            "on_close": {"kind": "return_treasury"},
            "success": null,
            "mandates": [{
                "principal": {"kind": "agent", "id": "bot"},
                "spend": [],
                "per_request_micros": null,
                "capabilities": ["claim_tasks"],
                "expires": null
            }],
            "rules": [{
                "id": rule_id("g", "rule close requires approve(core, 1)"),
                "subject": {"kind": "close"},
                "procedure": {"kind": "approve", "circle": "core", "count": 1},
                "within": d7,
                "else": "deny"
            }],
            "limits": {"unapproved_monthly_max_micros": 0}
        }]
    });
    assert_eq!(ir["ir_version"], json!(1));
    assert_eq!(ir["org"], expected);
    assert_eq!(
        ir["source_hash"],
        json!(maru_core::source_hash(src).unwrap())
    );
}

// ---- E3xx ----

// L03-T03
#[test]
fn l03_t03_duplicate_ids_are_e301_on_the_second() {
    let circle = in_org("  circle core {\n    seats: 1\n    holders: @sam\n  }\n");
    let agent = in_org("  agent builder {\n    operator: @jo\n  }\n");
    let goal = in_org("  goal g \"Again\" {\n    steward: core\n  }\n");
    for (src, decl) in [
        (&circle, "circle core"),
        (&agent, "agent builder"),
        (&goal, "goal g"),
    ] {
        let d = only(src, Code::E301);
        let id = decl.split(' ').nth(1).unwrap();
        assert_eq!(text(src, &d), id);
        let second = src.rfind(decl).unwrap() + decl.len() - id.len();
        assert_eq!(d.span.start.offset, second, "span on the second {decl}");
        let first = src.find(decl).unwrap();
        let (line, col) = line_col(src, id, first + decl.len() - id.len());
        let expected = format!("line {line}, column {col}");
        assert!(
            d.notes.iter().any(|n| n.contains(&expected)),
            "note for {decl} should point to {expected}: {:?}",
            d.notes
        );
    }
}

// L03-T04
#[test]
fn l03_t04_unknown_circle_is_e302_with_suggestions() {
    let steward = spec("", "").replace("steward: core", "steward: cor");
    let approve = in_goal("    rule spend requires approve(cor, 1)");
    let vote = in_goal("    rule spend requires vote(cor, 1/2)");
    let amend = spec("", "").replace("amend: approve(core, 1)", "amend: approve(cor, 1)");
    for src in [&steward, &approve, &vote, &amend] {
        let d = only(src, Code::E302);
        assert_eq!(text(src, &d), "cor");
        assert_eq!(d.notes, vec!["did you mean `core`?".to_string()]);
    }
    let unknown = [
        spec("", "").replace("steward: core", "steward: xyz"),
        in_goal("    rule spend requires approve(xyz, 1)"),
        in_goal("    rule spend requires vote(xyz, 1/2)"),
        spec("", "").replace("amend: approve(core, 1)", "amend: vote(xyz, 1/2)"),
    ];
    for src in &unknown {
        let d = only(src, Code::E302);
        assert_eq!(text(src, &d), "xyz");
        assert!(d.notes.is_empty(), "no suggestion for xyz: {:?}", d.notes);
    }
}

// L03-T05
#[test]
fn l03_t05_mandate_for_undeclared_agent_is_e303() {
    let src = in_goal("    mandate ghost {\n      can: claim_tasks\n    }");
    let d = only(&src, Code::E303);
    assert_eq!(text(&src, &d), "ghost");
}

// L03-T06
#[test]
fn l03_t06_missing_required_fields_are_e304() {
    let no_amend = spec("", "").replace("  amend: approve(core, 1)\n", "");
    let d = only(&no_amend, Code::E304);
    assert_eq!(text(&no_amend, &d), "\"T\"");

    let no_seats = in_org("  circle c2 {\n    holders: @sam\n  }\n");
    let d = only(&no_seats, Code::E304);
    assert_eq!(text(&no_seats, &d), "c2");

    let no_operator = spec(
        "  agent a2 {\n    runtime: hosted\n  }\n",
        "    mandate a2 {\n      can: claim_tasks\n    }",
    );
    let d = only(&no_operator, Code::E304);
    assert_eq!(text(&no_operator, &d), "a2");

    let no_steward = in_org("  goal g2 \"Two\" {\n    purpose \"p\"\n  }\n");
    let d = only(&no_steward, Code::E304);
    assert_eq!(text(&no_steward, &d), "g2");
}

// L03-T07
#[test]
fn l03_t07_fields_given_twice_are_e305() {
    let agent = |items: &str| {
        spec(
            &format!("  agent a2 {{\n{items}\n  }}\n"),
            "    mandate a2 {\n      can: claim_tasks\n    }",
        )
    };
    let circle = |items: &str| in_org(&format!("  circle c2 {{\n{items}\n  }}\n"));
    let mandate = |items: &str| in_goal(&format!("    mandate @jo {{\n{items}\n    }}"));
    let cases = [
        (circle("    seats: 3\n    seats: 4"), "seats: 4", "seats: 3"),
        (
            circle("    seats: 3\n    term: 1y\n    term: 2y"),
            "term: 2y",
            "term: 1y",
        ),
        (
            circle("    seats: 3\n    holders: @sam\n    holders: @kim"),
            "holders: @kim",
            "holders: @sam",
        ),
        (
            agent("    operator: @jo\n    operator: @sam"),
            "operator: @sam",
            "operator: @jo",
        ),
        (
            agent("    operator: @jo\n    runtime: byo\n    runtime: hosted"),
            "runtime: hosted",
            "runtime: byo",
        ),
        (
            in_goal(
                "    fund: usd 1_000 / month from treasury\n    fund: usd 2_000 / month from treasury",
            ),
            "fund: usd 2_000 / month from treasury",
            "fund: usd 1_000",
        ),
        (
            in_goal("    steward: core"),
            "steward: core",
            "steward: core",
        ),
        (
            mandate("      per_request <= usd 5\n      per_request <= usd 6"),
            "per_request <= usd 6",
            "per_request <= usd 5",
        ),
        (
            mandate("      expires: 2030-01-01\n      expires: 2031-01-01"),
            "expires: 2031-01-01",
            "expires: 2030-01-01",
        ),
    ];
    for (src, second, first) in &cases {
        let d = only(src, Code::E305);
        assert_eq!(text(src, &d), *second);
        // Each block's first field: anchor on the block so `core`'s fields don't match.
        let anchor = ["circle c2", "agent a2", "mandate @jo"]
            .into_iter()
            .find(|a| src.contains(a))
            .unwrap_or("");
        assert_points_to(src, &d, anchor, first);
    }
}

// L03-T08
#[test]
fn l03_t08_too_many_holders_is_e306_and_duplicate_holder_is_e323() {
    let src = in_org("  circle c2 {\n    seats: 1\n    holders: @sam, @kim\n  }\n");
    let d = only(&src, Code::E306);
    assert_eq!(text(&src, &d), "holders: @sam, @kim");

    let src = in_org("  circle c2 {\n    seats: 3\n    holders: @sam, @kim, @sam\n  }\n");
    let d = only(&src, Code::E323);
    assert_eq!(text(&src, &d), "@sam");
    assert_eq!(d.span.start.offset, src.rfind("@sam").unwrap());
    assert_points_to_first(&src, &d, "@sam");
}

// L03-T09
#[test]
fn l03_t09_approve_count_out_of_range_is_e307() {
    let zero = in_goal("    rule spend requires approve(core, 0)");
    let d = only(&zero, Code::E307);
    assert_eq!(text(&zero, &d), "0");

    let over = in_goal("    rule spend requires approve(core, 4)");
    let d = only(&over, Code::E307);
    assert_eq!(text(&over, &d), "4");

    ir_ok(&in_goal("    rule spend requires approve(core, 3)"));
}

// L03-T10
#[test]
fn l03_t10_threshold_out_of_range_is_e308() {
    for t in ["0/3", "4/3", "1/0", "0%", "101%"] {
        let src = in_goal(&format!("    rule close requires vote(core, {t})"));
        let d = only(&src, Code::E308);
        assert_eq!(text(&src, &d), t);
    }
    for t in ["1/1", "100%", "1%"] {
        ir_ok(&in_goal(&format!(
            "    rule close requires vote(core, {t})"
        )));
    }
}

// L03-T11
#[test]
fn l03_t11_money_zero_is_e309_and_parser_money_errors_are_reported_once() {
    let src = in_goal("    fund: usd 0 / month from treasury");
    let d = only(&src, Code::E309);
    assert_eq!(text(&src, &d), "usd 0");

    // 2^53 micros (one over the maximum) and 2^53 + 1 micros.
    for amount in ["9_007_199_254.740992", "9_007_199_254.740993"] {
        let src = in_goal(&format!("    fund: usd {amount} / month from treasury"));
        assert_codes(&src, &[Code::E310]);
    }
    let src = in_goal("    fund: usd 1.1234567 / month from treasury");
    assert_codes(&src, &[Code::E311]);
}

// L03-T12
#[test]
fn l03_t12_two_mandates_for_one_principal_is_e312() {
    let agent = in_goal("    mandate builder {\n      can: claim_tasks\n    }");
    let d = only(&agent, Code::E312);
    assert_eq!(text(&agent, &d), "builder");
    assert_eq!(d.span.start.offset, agent.rfind("builder").unwrap());
    assert_points_to(&agent, &d, "mandate builder", "builder");

    let person = in_goal(
        "    mandate @jo {\n      can: claim_tasks\n    }\n\n    mandate @jo {\n      can: post_evidence\n    }",
    );
    let d = only(&person, Code::E312);
    assert_eq!(text(&person, &d), "@jo");
    assert_eq!(d.span.start.offset, person.rfind("@jo").unwrap());
    assert_points_to(&person, &d, "mandate @jo", "@jo");
}

// L03-T13
#[test]
fn l03_t13_two_spend_lines_for_one_category_is_e313() {
    let src = in_goal(
        "    mandate @jo {\n      spend llm <= usd 10 / day\n      spend llm <= usd 50 / week\n    }",
    );
    let d = only(&src, Code::E313);
    assert_eq!(text(&src, &d), "spend llm <= usd 50 / week");
    assert_points_to_first(&src, &d, "spend llm <= usd 10 / day");
}

// L03-T14
#[test]
fn l03_t14_two_rules_with_one_subject_is_e314() {
    let identical = in_goal(
        "    rule spend llm > usd 5 requires approve(core, 1)\n    rule spend llm > usd 5 requires approve(core, 1)",
    );
    let d = only(&identical, Code::E314);
    assert_eq!(
        d.span.start.offset,
        identical.rfind("spend llm > usd 5").unwrap()
    );
    assert_points_to_first(&identical, &d, "spend llm > usd 5");

    let different = in_goal(
        "    rule close requires approve(core, 1)\n    rule close requires vote(core, 2/3) within 3d else deny",
    );
    let d = only(&different, Code::E314);
    assert_eq!(
        d.span.start.offset,
        different.rfind("close requires").unwrap()
    );
    assert_points_to_first(&different, &d, "close requires");
}

// L03-T15
#[test]
fn l03_t15_on_close_transfer_to_itself_or_unknown_goal_is_e315() {
    let itself = in_goal("    on_close: transfer g");
    let d = only(&itself, Code::E315);
    assert_eq!(text(&itself, &d), "g");

    let unknown = in_goal("    on_close: transfer nowhere");
    let d = only(&unknown, Code::E315);
    assert_eq!(text(&unknown, &d), "nowhere");
}

// L03-T16
#[test]
fn l03_t16_amend_that_holders_cannot_satisfy_is_e316() {
    let src = spec("", "").replace("amend: approve(core, 1)", "amend: approve(core, 3)");
    let d = only(&src, Code::E316);
    assert_eq!(text(&src, &d), "approve(core, 3)");

    let src = spec("  circle empty {\n    seats: 3\n  }\n", "")
        .replace("amend: approve(core, 1)", "amend: vote(empty, 1/2)");
    let d = only(&src, Code::E316);
    assert_eq!(text(&src, &d), "vote(empty, 1/2)");

    // `vote(members, …)` never deadlocks, even with no holders anywhere.
    ir_ok(&spec("", "").replace("amend: approve(core, 1)", "amend: vote(members, 1/2)"));
    ir_ok("org \"T\" {\n  amend: vote(members, 1/2)\n\n  circle core {\n    seats: 1\n  }\n}\n");
}

// L03-T17
#[test]
fn l03_t17_steward_circle_without_holders_is_e317() {
    let src = spec("  circle empty {\n    seats: 2\n  }\n", "")
        .replace("steward: core", "steward: empty");
    let d = only(&src, Code::E317);
    assert_eq!(text(&src, &d), "empty");
}

// L03-T18
#[test]
fn l03_t18_zero_duration_is_e319() {
    let term = in_org("  circle c2 {\n    seats: 1\n    term: 0d\n  }\n");
    let d = only(&term, Code::E319);
    assert_eq!(text(&term, &d), "0d");

    let within = in_goal("    rule close requires approve(core, 1) within 0d else deny");
    let d = only(&within, Code::E319);
    assert_eq!(text(&within, &d), "0d");
}

// L03-T19
#[test]
fn l03_t19_approve_members_is_e322() {
    let rule = in_goal("    rule spend requires approve(members, 1)");
    let d = only(&rule, Code::E322);
    assert_eq!(text(&rule, &d), "members");

    let amend = spec("", "").replace("amend: approve(core, 1)", "amend: approve(members, 1)");
    let d = only(&amend, Code::E322);
    assert_eq!(text(&amend, &d), "members");
}

// ---- W4xx ----

// L03-T20
#[test]
fn l03_t20_expired_mandate_is_w401_only_with_now() {
    let src =
        in_goal("    mandate @jo {\n      can: claim_tasks\n      expires: 2027-01-01\n    }");
    for now in [
        "2027-01-01T00:00:00Z",
        "2027-01-01T12:00:00Z",
        "2030-06-01T00:00:00Z",
    ] {
        let out = run_at(&src, now);
        assert_eq!(check_codes(&out), [Code::W401], "now = {now}");
        assert_eq!(text(&src, &out.diagnostics[0]), "2027-01-01");
        assert!(out.ir.is_some());
    }
    let out = run_at(&src, "2026-12-31T23:59:59Z");
    assert!(out.diagnostics.is_empty(), "{:#?}", out.diagnostics);
    ir_ok(&src);
}

// L03-T21
#[test]
fn l03_t21_else_allow_is_w402() {
    let rule = in_goal("    rule spend > usd 10 requires approve(core, 1) within 48h else allow");
    let d = only(&rule, Code::W402);
    assert_eq!(text(&rule, &d), "within 48h else allow");

    let amend = spec("", "").replace(
        "amend: approve(core, 1)",
        "amend: approve(core, 1) within 3d else allow",
    );
    let d = only(&amend, Code::W402);
    assert_eq!(text(&amend, &d), "within 3d else allow");
}

// L03-T22
#[test]
fn l03_t22_spend_limit_above_fund_is_w403() {
    let with = |fund: &str, spend: &str| {
        in_goal(&format!(
            "    fund: {fund} from treasury\n\n    mandate @jo {{\n      spend expense <= {spend}\n    }}"
        ))
    };
    let src = with("usd 1_000 / month", "usd 50 / day");
    let d = only(&src, Code::W403);
    assert_eq!(text(&src, &d), "spend expense <= usd 50 / day");

    ir_ok(&with("usd 1_000 / month", "usd 900 / month"));
    ir_ok(&with("usd 1_000 once", "usd 50 / day"));
    ir_ok(&with("usd 1 once", "usd 1_000_000 / month"));
}

// L03-T23
#[test]
fn l03_t23_w404_w405_w406_w408() {
    let src = in_goal("    on_underfunded: continue");
    let d = only(&src, Code::W404);
    assert_eq!(text(&src, &d), "on_underfunded: continue");

    let src = in_goal(
        "    mandate @jo {\n      spend llm <= usd 10 / day\n      spend compute <= usd 5 / week\n      per_request <= usd 11\n    }",
    );
    let d = only(&src, Code::W405);
    assert_eq!(text(&src, &d), "per_request <= usd 11");
    // Not above every limit: no warning.
    ir_ok(&src.replace("usd 11", "usd 10"));

    let src = in_org("  agent idle {\n    operator: @jo\n  }\n");
    let d = only(&src, Code::W406);
    assert_eq!(text(&src, &d), "idle");

    let src = in_goal(
        "    mandate @jo {\n      can: claim_tasks, report_metric(m), claim_tasks, report_metric(m)\n    }",
    );
    let out = assert_codes(&src, &[Code::W408, Code::W408]);
    let second = src.rfind("claim_tasks").unwrap();
    assert_eq!(out.diagnostics[0].span.start.offset, second);
    assert_eq!(text(&src, &out.diagnostics[1]), "report_metric(m)");
    assert_eq!(
        out.ir.unwrap().org.goals[0].mandates[1].capabilities,
        ["claim_tasks", "report_metric:m"]
    );
}

// L03-T24
#[test]
fn l03_t24_warnings_keep_the_ir_and_errors_drop_it() {
    let warnings = in_goal(
        "    on_underfunded: pause\n    rule close requires approve(core, 1) within 1d else allow",
    );
    let out = assert_codes(&warnings, &[Code::W404, Code::W402]);
    assert!(out.ir.is_some());

    let error = warnings.replace("approve(core, 1) within", "approve(core, 9) within");
    let out = run(&error);
    assert!(out.diagnostics.iter().any(|d| d.code == Code::E307));
    assert!(out.ir.is_none());
}

// L03-T25
#[test]
fn l03_t25_rule_ids_are_stable_hashes_of_the_rule_line() {
    let lines = [
        "rule spend > usd 500 requires approve(core, 1) within 48h else deny",
        "rule spend expense requires approve(core, 1) within 7d else deny",
        "rule close requires vote(core, 2/3) within 7d else deny",
    ];
    let ids = |src: &str| -> Vec<String> {
        ir_ok(src).org.goals[0]
            .rules
            .iter()
            .map(|r| r.id.clone())
            .collect()
    };
    let lumen = ids(LUMEN);
    for (id, line) in lumen.iter().zip(lines) {
        assert!(is_rule_id(id), "{id}");
        assert_eq!(*id, rule_id("editor", line));
    }

    let block = lines.map(|l| format!("    {l}\n")).concat();
    let reversed = lines
        .iter()
        .rev()
        .map(|l| format!("    {l}\n"))
        .collect::<String>();
    let mut reordered = ids(&LUMEN.replace(&block, &reversed));
    reordered.reverse();
    assert_eq!(reordered, lumen);

    let changed = ids(&LUMEN.replace(
        "rule spend expense requires approve(core, 1)",
        "rule spend expense requires approve(core, 2)",
    ));
    assert_eq!(changed[0], lumen[0]);
    assert_ne!(changed[1], lumen[1]);
    assert!(is_rule_id(&changed[1]));
    assert_eq!(changed[2], lumen[2]);
}

// L03-T26
#[test]
fn l03_t26_thresholds_unreduced_and_durations_keep_their_unit() {
    let src = in_goal(
        "    rule close requires vote(core, 60%) within 48h else deny\n    rule spend requires vote(members, 2/4) within 90m else deny",
    );
    let rules = &lumen_goal(&src)["rules"];
    assert_eq!(
        rules[0]["procedure"]["threshold"],
        json!({"num": 60, "den": 100, "percent": true})
    );
    assert_eq!(
        rules[0]["within"],
        json!({"value": 48, "unit": "h", "secs": 172800})
    );
    assert_eq!(
        rules[1]["procedure"],
        json!({"kind": "vote", "circle": null, "threshold": {"num": 2, "den": 4, "percent": false}})
    );
    assert_eq!(
        rules[1]["within"],
        json!({"value": 90, "unit": "m", "secs": 5400})
    );
}

// L03-T27
#[test]
fn l03_t27_limits_analysis() {
    // (a) lumen.
    assert_eq!(monthly_max(LUMEN), 5_000_000_000);
    // (b) without the `spend expense` rule, @jo's expense line counts.
    let no_expense_rule = lumen_with(
        "    rule spend expense requires approve(core, 1) within 7d else deny\n",
        "",
    );
    assert_eq!(monthly_max(&no_expense_rule), 5_500_000_000);
    // (c) an unthresholded `else deny` rule for llm excludes the llm lines.
    let llm_rule = lumen_with(
        "    rule close requires",
        "    rule spend llm requires approve(core, 1)\n    rule close requires",
    );
    assert_eq!(monthly_max(&llm_rule), 1_000_000_000);
    // (d) a thresholded rule excludes nothing.
    let thresholded = in_goal("    rule spend llm > usd 1 requires approve(core, 1)");
    assert_eq!(monthly_max(&thresholded), 100_000_000);
    // (e) an `else allow` rule excludes nothing (and warns).
    let allow = in_goal("    rule spend llm requires approve(core, 1) within 1d else allow");
    let out = assert_codes(&allow, &[Code::W402]);
    assert_eq!(
        out.ir.unwrap().org.goals[0]
            .limits
            .unapproved_monthly_max_micros,
        100_000_000
    );
    // (f) week ×6, day ×31.
    let periods = in_goal(
        "    mandate @jo {\n      spend compute <= usd 10 / week\n      spend expense <= usd 1 / day\n    }",
    );
    assert_eq!(monthly_max(&periods), 100_000_000 + 60_000_000 + 31_000_000);
    // (g) a goal with no mandates.
    let no_mandates = spec("", "").replace(
        "    mandate builder {\n      spend llm <= usd 100 / month\n    }\n",
        "",
    );
    let out = assert_codes(&no_mandates, &[Code::W406]);
    assert_eq!(
        out.ir.unwrap().org.goals[0]
            .limits
            .unapproved_monthly_max_micros,
        0
    );
}

// L03-T28
#[test]
fn l03_t28_diagnostics_sorted_and_output_deterministic() {
    // Errors and warnings found in different passes, in source order once sorted.
    let src = "org \"T\" {
  circle core {
    seats: 2
    holders: @mina, @mina
  }

  agent idle {
    operator: @mina
  }

  agent idle {
    operator: @jo
  }

  goal g \"G\" {
    steward: cor
    on_underfunded: pause

    mandate ghost {
      spend llm <= usd 0 / day
      can: claim_tasks, claim_tasks
    }

    rule close requires approve(members, 1) within 1d else allow
    rule close requires vote(core, 0%)
  }
}
";
    let out = run(src);
    assert_eq!(
        check_codes(&out),
        [
            Code::E304,
            Code::E323,
            Code::W406,
            Code::E301,
            Code::E302,
            Code::W404,
            Code::E303,
            Code::E309,
            Code::W408,
            Code::E322,
            Code::W402,
            Code::E314,
            Code::E308,
        ],
        "{:#?}",
        out.diagnostics
    );
    let first = serde_json::to_string(&out).unwrap();
    for _ in 0..20 {
        assert_eq!(serde_json::to_string(&run(src)).unwrap(), first);
    }
    let lumen = serde_json::to_string(&run(LUMEN)).unwrap();
    assert_eq!(serde_json::to_string(&run(LUMEN)).unwrap(), lumen);
}

// L03-T29
#[test]
fn l03_t29_ir_validates_against_the_schema() {
    let ir: Value = serde_json::from_str(GOLDEN).unwrap();
    assert_schema_valid(&ir);
    // `run` validated every IR above and in the other tests; check a varied one here too.
    let varied = spec(
        "  agent helper {\n    operator: @jo\n    runtime: byo\n  }\n\n  goal h \"H\" {\n    steward: core\n    fund: usd 0.50 once from treasury\n    on_underfunded: continue\n    on_close: transfer g\n    success: metric(m) < -0.5\n\n    mandate helper {\n      spend compute <= usd 1 / day\n      can: create_tasks\n    }\n  }\n",
        "    fund: usd 70 / week from treasury\n    rule spend requires vote(members, 99%) within 1y else deny",
    )
    .replace("amend: approve(core, 1)", "members: open()\n  amend: vote(core, 1/2)");
    let ir = ir_json(&varied);
    assert_eq!(ir["org"]["membership"], json!({"kind": "open"}));
    // Goal `h` comes first: org items precede goal `g` in `spec`.
    let h = &ir["org"]["goals"][0];
    assert_eq!(
        h["fund"],
        json!({"amount_micros": 500_000, "period": "once"})
    );
    assert_eq!(h["on_close"], json!({"kind": "transfer", "goal": "g"}));
    assert_eq!(
        h["limits"]["unapproved_monthly_max_micros"],
        json!(31_000_000)
    );
    assert_eq!(
        ir["org"]["goals"][1]["fund"],
        json!({"amount_micros": 70_000_000, "period": "week"})
    );
    assert_eq!(
        h["success"],
        json!({"metric": "m", "cmp": "<", "value": "-0.5", "by": null})
    );
}

// L03 acceptance criterion: the schema rejects an IR missing any required field (and
// extra fields or wrong types).
#[test]
fn l03_schema_rejects_an_ir_missing_any_field() {
    fn paths(v: &Value, at: Vec<String>, out: &mut Vec<Vec<String>>) {
        match v {
            Value::Object(map) => {
                for (k, child) in map {
                    let mut p = at.clone();
                    p.push(k.clone());
                    out.push(p.clone());
                    paths(child, p, out);
                }
            }
            Value::Array(items) => {
                for (i, child) in items.iter().enumerate() {
                    let mut p = at.clone();
                    p.push(i.to_string());
                    paths(child, p, out);
                }
            }
            _ => {}
        }
    }
    fn parent<'a>(v: &'a mut Value, path: &[String]) -> &'a mut Value {
        path.iter().fold(v, |v, k| match v {
            Value::Array(items) => &mut items[k.parse::<usize>().unwrap()],
            _ => &mut v[k.as_str()],
        })
    }
    // Lumen plus the minimal org, so nullable fields are seen both null and set.
    let lumen: Value = serde_json::from_str(GOLDEN).unwrap();
    let minimal = ir_json(&in_goal("    rule close requires vote(members, 50%)"));
    for ir in [lumen, minimal] {
        let mut all = Vec::new();
        paths(&ir, Vec::new(), &mut all);
        assert!(all.len() > 50);
        for path in all {
            let mut broken = ir.clone();
            let (key, at) = path.split_last().unwrap();
            parent(&mut broken, at).as_object_mut().unwrap().remove(key);
            assert!(
                !schema_errors(&broken).is_empty(),
                "schema accepts the IR without {}",
                path.join(".")
            );
        }
        let mut extra = ir.clone();
        extra["org"]["goals"][0]["unexpected"] = json!(1);
        assert!(!schema_errors(&extra).is_empty(), "extra field accepted");
        let mut wrong = ir.clone();
        wrong["org"]["goals"][0]["limits"]["unapproved_monthly_max_micros"] = json!("5");
        assert!(!schema_errors(&wrong).is_empty(), "string money accepted");
        let mut version = ir.clone();
        version["ir_version"] = json!(2);
        assert!(!schema_errors(&version).is_empty(), "ir_version 2 accepted");
    }
}

// ---- stage 1 ----

// L03-T31
#[test]
fn l03_t31_parse_errors_stop_semantic_checks() {
    let src = in_org("  circle c2 {\n    seats: 3x\n  }\n");
    assert_codes(&src, &[Code::E103]);

    let src = spec("", "").replace("holders: @mina, @jo", "holders: @A");
    assert_codes(&src, &[Code::E106]);

    let src =
        in_goal("    fund: usd 9_007_199_255 / month from treasury\n    on_underfunded: pause");
    assert_codes(&src, &[Code::E310]);
}

// L03-T32
#[test]
fn l03_t32_monthly_limit_over_the_money_maximum_is_e318() {
    let line = |amount: &str| {
        spec("", "").replace(
            "spend llm <= usd 100 / month",
            &format!("spend llm <= usd {amount} / day"),
        )
    };
    let over = line("300_000_000");
    let d = only(&over, Code::E318);
    assert_eq!(text(&over, &d), "g");

    let under = line("290_000_000");
    assert_eq!(monthly_max(&under), 290_000_000 * 31 * 1_000_000);

    let excluded = line("300_000_000").replace(
        "    }\n\n  }\n}",
        "    }\n\n    rule spend llm requires approve(core, 1)\n  }\n}",
    );
    assert!(excluded.contains("rule spend llm requires"));
    assert_eq!(monthly_max(&excluded), 0);

    let max = "usd 9_007_199_254.740991 / day";
    let mandates: String = (1..=40)
        .map(|i| {
            format!(
                "\n    mandate @a{i} {{\n      spend llm <= {max}\n      spend compute <= {max}\n      spend expense <= {max}\n    }}\n"
            )
        })
        .collect();
    let src = in_goal(&mandates);
    let d = only(&src, Code::E318);
    assert_eq!(text(&src, &d), "g");
    assert_eq!(MAX_MONEY_MICROS, 9_007_199_254_740_991);
}

// L03-T33
#[test]
fn l03_t33_rules_with_one_id_in_a_goal_is_e325() {
    // Different subjects whose hashes share the first 8 hex characters (OQ-15).
    let first = "rule spend > usd 14_097 requires approve(core, 1)";
    let second = "rule spend > usd 104_588 requires approve(core, 1)";
    assert_eq!(rule_id("g", first), "g:r_239bc3bc");
    assert_eq!(rule_id("g", second), "g:r_239bc3bc");

    let src = in_goal(&format!("    {first}\n    {second}"));
    let d = only(&src, Code::E325);
    assert_eq!(text(&src, &d), second);
    assert_points_to_first(&src, &d, first);
    assert!(d.message.contains("`g:r_239bc3bc`"), "{}", d.message);

    // Ids start with the goal id, so the rules can sit in different goals.
    let apart = spec(
        &format!("  goal h \"H\" {{\n    steward: core\n\n    {second}\n  }}\n"),
        &format!("    {first}"),
    );
    let ir = ir_ok(&apart);
    let ids: Vec<&str> = ir
        .org
        .goals
        .iter()
        .flat_map(|g| g.rules.iter().map(|r| r.id.as_str()))
        .collect();
    assert_eq!(ids, ["h:r_239bc3bc", "g:r_239bc3bc"]);

    // Two identical rules repeat a subject: E314 alone.
    let identical = in_goal(&format!("    {first}\n    {first}"));
    only(&identical, Code::E314);
}

// ---- additional edge cases ----

// L03 extra: suggestions for unknown agents and goals, and `members` for a vote.
#[test]
fn l03_suggestions_for_agents_goals_and_members() {
    let src = in_goal("    mandate buildr {\n      can: claim_tasks\n    }");
    let d = only(&src, Code::E303);
    assert_eq!(d.notes, ["did you mean `builder`?"]);

    let src = in_org("  goal g2 \"Two\" {\n    steward: core\n  }\n").replace(
        "    steward: core\n\n    mandate builder",
        "    steward: core\n    on_close: transfer g3\n\n    mandate builder",
    );
    let d = only(&src, Code::E315);
    assert_eq!(text(&src, &d), "g3");
    assert_eq!(d.notes, ["did you mean `g2`?"]);

    let src = in_goal("    rule close requires vote(member, 1/2)");
    let d = only(&src, Code::E302);
    assert_eq!(d.notes, ["did you mean `members`?"]);
    // `approve` cannot take `members`, so it is not suggested there.
    let src = in_goal("    rule close requires approve(member, 1)");
    let d = only(&src, Code::E302);
    assert!(d.notes.is_empty(), "{:?}", d.notes);
}

// L03 extra: E305 covers every single-valued field, not only those listed in T07.
#[test]
fn l03_other_single_valued_fields_given_twice_are_e305() {
    let org =
        |item: &str| spec("", "").replace("  amend:", &format!("  {item}\n  {item}\n  amend:"));
    let cases = [
        org("purpose \"a\""),
        org("members: open()"),
        spec("", "").replace(
            "  amend: approve(core, 1)\n",
            "  amend: approve(core, 1)\n  amend: approve(core, 1)\n",
        ),
        in_goal("    purpose \"a\"\n    purpose \"b\""),
        in_goal(
            "    fund: usd 1_000 / day from treasury\n    on_underfunded: pause\n    on_underfunded: continue",
        ),
        in_goal("    on_close: return treasury\n    on_close: return treasury"),
        in_goal("    success: metric(m) > 1\n    success: metric(m) > 2"),
        in_goal("    mandate @jo {\n      can: claim_tasks\n      can: post_evidence\n    }"),
    ];
    for src in &cases {
        assert_codes(src, &[Code::E305]);
    }
}

// L03 extra: circles, agents and goals have separate id namespaces.
#[test]
fn l03_ids_of_different_kinds_may_coincide() {
    let src = spec(
        "  agent core {\n    operator: @jo\n  }\n",
        "    mandate core {\n      can: claim_tasks\n    }",
    )
    .replace("goal g \"G\"", "goal core \"G\"");
    ir_ok(&src);
}

// L03 extra: duplicate holders are counted once against the seats (no E306 cascade).
#[test]
fn l03_duplicate_holders_count_once_against_seats() {
    let src = in_org("  circle c2 {\n    seats: 1\n    holders: @sam, @sam\n  }\n");
    assert_codes(&src, &[Code::E323]);
}

// L03 extra: every money literal must be positive.
#[test]
fn l03_every_money_literal_must_be_positive() {
    for (src, at) in [
        (
            in_goal("    mandate @jo {\n      spend llm <= usd 0.000000 / day\n    }"),
            "usd 0.000000",
        ),
        (
            in_goal(
                "    mandate @jo {\n      spend llm <= usd 1 / day\n      per_request <= usd 0\n    }",
            ),
            "usd 0",
        ),
        (
            in_goal("    rule spend > usd 0 requires approve(core, 1)"),
            "usd 0",
        ),
    ] {
        let d = only(&src, Code::E309);
        assert_eq!(text(&src, &d), at);
    }
}

// L03 extra: zero seats or sponsors (OQ-10).
#[test]
fn l03_seats_and_sponsors_must_be_at_least_one() {
    let src = in_org("  circle c2 {\n    seats: 0\n  }\n");
    let d = only(&src, Code::E324);
    assert_eq!(text(&src, &d), "0");

    let src = spec("", "").replace("  amend:", "  members: invite(sponsors: 0)\n  amend:");
    let d = only(&src, Code::E324);
    assert_eq!(text(&src, &d), "0");
}

// L03 extra: an over-size formatted source is a stage-1 E109 (SPEC-01 §1), with no IR.
#[test]
fn l03_formatted_source_over_the_size_limit_is_e109() {
    let holders: Vec<String> = (0..31_000).map(|i| format!("@h{i}")).collect();
    let src = in_org(&format!(
        "  circle c2 {{\n    seats: 1\n    holders:{}\n  }}\n",
        holders.join(",")
    ));
    assert!(
        src.len() <= MAX_SOURCE_BYTES,
        "input is {} bytes",
        src.len()
    );
    assert_codes(&src, &[Code::E109]);
}

// L03 extra: options deserialize from JSON (the NIF and WASM pass `opts_json`).
#[test]
fn l03_check_options_from_json() {
    let opts: CheckOptions = serde_json::from_str(r#"{"now":"2027-01-01T00:00:00Z"}"#).unwrap();
    assert_eq!(opts.now, Some("2027-01-01T00:00:00Z".parse().unwrap()));
    let opts: CheckOptions = serde_json::from_str("{}").unwrap();
    assert_eq!(opts, CheckOptions::default());
    assert!(serde_json::from_str::<CheckOptions>(r#"{"nw":null}"#).is_err());
}

// L03 extra: the output serializes as `{"diagnostics": […], "ir": …}` (SPEC-01 §5).
#[test]
fn l03_output_json_shape() {
    let src = in_goal("    rule close requires vote(core, 0%)");
    let out = check(&src, &CheckOptions::default());
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(v["ir"], Value::Null);
    let d = &v["diagnostics"][0];
    assert_eq!(d["code"], json!("E308"));
    assert_eq!(d["severity"], json!("error"));
    assert!(d["span"]["start"]["line"].is_u64());
    assert!(d["notes"].is_array());
}

// L03 extra: suggestion lookups share a work budget, so thousands of unknown references
// cannot make a check slow. Here 3,000 declared agents and 400 unknown principals that
// are not close to any of them spend the budget, so a later near miss gets no note, while
// the same near miss on its own does.
#[test]
fn l03_suggestions_have_a_work_budget() {
    let agents: String = (0..3_000)
        .map(|i| format!("\n  agent a{i:05} {{\n    operator: @mina\n  }}\n"))
        .collect();
    let far: String = (0..400)
        .map(|i| format!("\n    mandate xyz{i:03} {{}}\n"))
        .collect();
    let near = "\n    mandate a0000 {}\n";
    let lone = spec(&agents, near);
    let d = run(&lone)
        .diagnostics
        .into_iter()
        .find(|d| d.code == Code::E303)
        .unwrap();
    assert_eq!(d.notes, ["did you mean `a00000`?"]);

    let flood = spec(&agents, &format!("{far}{near}"));
    let out = run(&flood);
    let unknown: Vec<_> = out
        .diagnostics
        .iter()
        .filter(|d| d.code == Code::E303)
        .collect();
    assert_eq!(unknown.len(), 401);
    assert!(unknown.iter().all(|d| d.notes.is_empty()));
}

// L03 extra: W403 needs a limit strictly above the fund; equal amounts are fine, also
// across periods (`usd 10 / week` is 60 a month).
#[test]
fn l03_spend_limit_equal_to_the_fund_does_not_warn() {
    let with = |fund: &str, spend: &str| {
        in_goal(&format!(
            "    fund: {fund} from treasury\n\n    mandate @jo {{\n      spend expense <= {spend}\n    }}"
        ))
    };
    // `builder`'s `spend llm <= usd 100 / month` equals the fund too.
    ir_ok(&with("usd 100 / month", "usd 100 / month"));
    let with_60 = |fund: &str, spend: &str| {
        with(fund, spend).replace(
            "spend llm <= usd 100 / month",
            "spend llm <= usd 60 / month",
        )
    };
    ir_ok(&with_60("usd 60 / month", "usd 10 / week"));
    let src = with_60("usd 60 / month", "usd 10.000001 / week");
    let d = only(&src, Code::W403);
    assert_eq!(text(&src, &d), "spend expense <= usd 10.000001 / week");
}
