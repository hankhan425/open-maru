//! L02 formatter tests: lumen round trips, numeric literals, blank lines, comments, lists,
//! item order, syntax errors, line endings, strings and the spec hash.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::ast::*;
use maru_core::fmt::rule_line;
use maru_core::parser::MAX_SOURCE_BYTES;
use maru_core::{Code, format, parse, source_hash};
use support::*;

/// Lumen with an ugly layout and the same AST (L02 deliverable).
const LUMEN_MESSY: &str = include_str!("fixtures/lumen.messy.maru");

/// `source_hash(lumen.maru)`: SHA-256 of the fixture's bytes, since it is canonical.
const LUMEN_HASH: &str = "sha256:5abc7fefcaa0af2efe04b1b5d40196ea10ec95db1a7d6e609e51d840086f8a83";

/// Formats `src`, failing the test on syntax errors.
fn fmt_ok(src: &str) -> String {
    match format(src) {
        Ok(out) => out,
        Err(diags) => panic!("format failed for {src:?}: {diags:#?}"),
    }
}

/// Whether `out` has a line that is `line` after indentation.
fn has_line(out: &str, line: &str) -> bool {
    out.lines().any(|l| l.trim_start_matches(' ') == line)
}

// L02-T01
#[test]
fn l02_t01_lumen_is_already_canonical() {
    assert_eq!(fmt_ok(LUMEN), LUMEN);
}

// L02-T02
#[test]
fn l02_t02_messy_lumen_formats_to_lumen() {
    assert_eq!(
        ast_json_no_trivia(&parse_ok(LUMEN_MESSY)),
        ast_json_no_trivia(&parse_ok(LUMEN)),
        "the messy fixture must have lumen's AST"
    );
    assert_eq!(fmt_ok(LUMEN_MESSY), LUMEN);
}

// L02-T03
#[test]
fn l02_t03_numeric_literals() {
    // Whole numbers, in every numeric position: money, count and metric value.
    let whole = [
        ("500", "500"),
        ("4000", "4_000"),
        ("12000", "12_000"),
        ("1_0", "10"),
        ("1234567", "1_234_567"),
    ];
    for (input, want) in whole {
        let out = fmt_ok(&mandate_with(&format!("      per_request <= usd {input}")));
        let line = format!("per_request <= usd {want}");
        assert!(has_line(&out, &line), "money {input} → {want}:\n{out}");

        let out = fmt_ok(&circle_with(&format!("    seats: {input}")));
        assert!(
            has_line(&out, &format!("seats: {want}")),
            "count {input}:\n{out}"
        );

        let out = fmt_ok(&goal_with(&format!("    success: metric(m) >= {input}")));
        let line = format!("success: metric(m) >= {want}");
        assert!(has_line(&out, &line), "metric {input}:\n{out}");
    }

    let money = [
        ("12.5", "12.50"),
        ("3.000100", "3.0001"),
        ("7.00", "7"),
        ("0.000125", "0.000125"),
    ];
    for (input, want) in money {
        let out = fmt_ok(&mandate_with(&format!("      per_request <= usd {input}")));
        let line = format!("per_request <= usd {want}");
        assert!(has_line(&out, &line), "money {input} → {want}:\n{out}");
    }

    let metric = [("10000", "10_000"), ("-1500.5", "-1_500.5")];
    for (input, want) in metric {
        let out = fmt_ok(&goal_with(&format!("    success: metric(m) >= {input}")));
        let line = format!("success: metric(m) >= {want}");
        assert!(has_line(&out, &line), "metric {input} → {want}:\n{out}");
    }
}

// L02-T04
#[test]
fn l02_t04_blank_lines() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "one blank line before and after each block item, none at block start or end",
            "org \"T\" {\ncircle core {\nseats: 3\n}\namend: approve(core, 1)\nagent a {\noperator: @mina\n}\npurpose \"p\"\nmembers: open()\ngoal g \"G\" {\nsteward: core\n}\n}\n",
            "org \"T\" {\n  circle core {\n    seats: 3\n  }\n\n  amend: approve(core, 1)\n\n  agent a {\n    operator: @mina\n  }\n\n  purpose \"p\"\n  members: open()\n\n  goal g \"G\" {\n    steward: core\n  }\n}\n",
        ),
        (
            "never two blank lines in a row; extra blank lines are dropped",
            "\n\norg \"T\" {\n\n\n  amend: approve(core, 1)\n\n\n\n  circle a {\n\n    seats: 1\n\n  }\n  circle b {\n    seats: 1\n  }\n\n\n}\n\n\n",
            "org \"T\" {\n  amend: approve(core, 1)\n\n  circle a {\n    seats: 1\n  }\n\n  circle b {\n    seats: 1\n  }\n}\n",
        ),
        (
            "one blank line before the first rule after a non-rule item, none between rules",
            "org \"T\" {\n  amend: approve(core, 1)\n  goal g \"G\" {\n    steward: core\n    rule close requires approve(core, 1)\n\n    rule spend requires approve(core, 1)\n    purpose \"p\"\n    rule spend llm requires approve(core, 1)\n  }\n}\n",
            "org \"T\" {\n  amend: approve(core, 1)\n\n  goal g \"G\" {\n    steward: core\n\n    rule close requires approve(core, 1)\n    rule spend requires approve(core, 1)\n    purpose \"p\"\n\n    rule spend llm requires approve(core, 1)\n  }\n}\n",
        ),
        (
            "a rule at block start has none; a rule after a mandate has exactly one",
            "org \"T\" {\n  amend: approve(core, 1)\n  goal g \"G\" {\n    rule close requires approve(core, 1)\n    mandate @jo {\n      can: claim_tasks\n    }\n    rule spend requires approve(core, 1)\n  }\n}\n",
            "org \"T\" {\n  amend: approve(core, 1)\n\n  goal g \"G\" {\n    rule close requires approve(core, 1)\n\n    mandate @jo {\n      can: claim_tasks\n    }\n\n    rule spend requires approve(core, 1)\n  }\n}\n",
        ),
        (
            "the blank line goes above the item's leading comments; comments after a block item are set off too",
            "org \"T\" {\n  amend: approve(core, 1)\n  # the core circle\n  circle core {\n    seats: 1\n  }\n  # end note\n}\n",
            "org \"T\" {\n  amend: approve(core, 1)\n\n  # the core circle\n  circle core {\n    seats: 1\n  }\n\n  # end note\n}\n",
        ),
    ];
    for (name, input, want) in cases {
        assert_eq!(fmt_ok(input), *want, "{name}");
        assert_eq!(fmt_ok(want), *want, "{name}: the output is canonical");
    }
}

// L02-T05
#[test]
fn l02_t05_comments_keep_their_place() {
    let src = "   # top of file\norg \"T\" {\n        # about amend\namend: approve(core, 1)      # trailing\n  circle core {   # open\n# about seats\n         seats: 3\t# three\n   # before the brace\n}    # after the circle\n# end of org\n}  # after org\n# after the file\n";
    let want = "# top of file\norg \"T\" {\n  # about amend\n  amend: approve(core, 1) # trailing\n\n  circle core { # open\n    # about seats\n    seats: 3 # three\n    # before the brace\n  } # after the circle\n\n  # end of org\n} # after org\n# after the file\n";
    assert_eq!(fmt_ok(src), want);
    assert_eq!(fmt_ok(want), want);
}

// L02 extra: a comment between the tokens of an item is one of its leading comments
// (SPEC-01 §2, ast module docs), so it moves above the item.
#[test]
fn l02_comment_inside_an_item_moves_above_it() {
    let src = circle_with("    holders: @ab, # between tokens\n      @cd");
    let out = fmt_ok(&src);
    assert!(
        out.contains("\n    # between tokens\n    holders: @ab, @cd\n"),
        "{out}"
    );
    assert_eq!(fmt_ok(&out), out);
}

// L02-T06
#[test]
fn l02_t06_lists_are_comma_space_separated() {
    let out = fmt_ok(&circle_with("    holders:@ab,@cd ,   @ef ,\n  @gh"));
    assert!(has_line(&out, "holders: @ab, @cd, @ef, @gh"), "{out}");

    let out = fmt_ok(&mandate_with(
        "      can:claim_tasks ,post_evidence,report_metric( m ),\n create_tasks",
    ));
    let line = "can: claim_tasks, post_evidence, report_metric(m), create_tasks";
    assert!(has_line(&out, line), "{out}");
}

// L02-T07
#[test]
fn l02_t07_item_order_is_preserved() {
    let src = "org \"T\" {\ngoal g \"G\" {\nrule close requires approve(core, 1)\nmandate builder {\nexpires: 2027-01-01\ncan: claim_tasks\n}\npurpose \"p\"\nsteward: core\n}\nagent builder {\nruntime: hosted\noperator: @mina\n}\ncircle core {\nholders: @mina\nseats: 1\n}\namend: approve(core, 1)\n}\n";
    let want = "org \"T\" {\n  goal g \"G\" {\n    rule close requires approve(core, 1)\n\n    mandate builder {\n      expires: 2027-01-01\n      can: claim_tasks\n    }\n\n    purpose \"p\"\n    steward: core\n  }\n\n  agent builder {\n    runtime: hosted\n    operator: @mina\n  }\n\n  circle core {\n    holders: @mina\n    seats: 1\n  }\n\n  amend: approve(core, 1)\n}\n";
    assert_eq!(fmt_ok(src), want);
}

// L02-T08
#[test]
fn l02_t08_syntax_errors_return_the_diagnostics() {
    let sources = [
        String::new(),
        "org".to_string(),
        "org \"T\" {".to_string(),
        "org \"T\" { amend: approve(core, 1) } extra".to_string(),
        "org \"T\" { amend: approve(core, 1) $ }".to_string(),
        // The parser drops an item with an error; the formatter must not drop it silently.
        circle_with("    seats: x"),
        mandate_with("      per_request <= usd 1.1234567"),
        LUMEN.replace("seats: 3", "seats 3"),
        LUMEN.replace("\"Lumen Studio\"", "\"Lumen Studio"),
    ];
    for src in &sources {
        let diagnostics = parse(src).diagnostics;
        assert!(!diagnostics.is_empty(), "expected syntax errors in {src:?}");
        assert_eq!(format(src), Err(diagnostics.clone()), "format({src:?})");
        assert_eq!(source_hash(src), Err(diagnostics), "source_hash({src:?})");
    }
}

// L02-T11
#[test]
fn l02_t11_crlf_input_is_normalized() {
    let crlf = LUMEN.replace('\n', "\r\n");
    assert_eq!(fmt_ok(&crlf), LUMEN);
    let messy_crlf = LUMEN_MESSY.replace('\n', "\r\n");
    assert_eq!(fmt_ok(&messy_crlf), LUMEN);
}

// L02-T11
#[test]
fn l02_t11_output_is_lf_without_trailing_whitespace_with_one_final_newline() {
    let inputs = [
        LUMEN.to_string(),
        LUMEN_MESSY.to_string(),
        LUMEN.trim_end().to_string(),
        format!("{LUMEN}\n\n\n"),
        format!("\n\n{}   \t", LUMEN.replace('\n', "  \r\n")),
        "org \"T\" {   \r\n  amend: approve(core, 1)   # note \t \r\n}  # end\t\r\n\r\n# after   "
            .to_string(),
    ];
    for src in &inputs {
        assert_clean_text(&fmt_ok(src));
    }
    let out = fmt_ok(&inputs[5]);
    assert_eq!(
        out,
        "org \"T\" {\n  amend: approve(core, 1) # note\n} # end\n# after\n"
    );
}

// L02-T12
#[test]
fn l02_t12_strings_use_canonical_escapes() {
    let literals = [
        r#""say \"hi\" to C:\\maru\nthen leave""#,
        r#""""#,
        r#""\\n is not a newline""#,
        "\"tab\there, # not a comment, {braces} and ünïcödé 🦀\"",
    ];
    for literal in literals {
        let src = org_with(&format!("  purpose {literal}\n  goal g {literal} {{\n  }}"));
        let out = fmt_ok(&src);
        assert!(has_line(&out, &format!("purpose {literal}")), "{out}");
        assert!(has_line(&out, &format!("goal g {literal} {{}}")), "{out}");
        // The content is unchanged.
        let strings = |f: &File| -> Vec<String> {
            org_items(f)
                .into_iter()
                .filter_map(|i| match i {
                    OrgItem::Purpose(s) => Some(s.value.clone()),
                    OrgItem::Goal(g) => Some(g.title.value.clone()),
                    _ => None,
                })
                .collect()
        };
        let before = strings(&parse_ok(&src));
        assert_eq!(before.len(), 2);
        assert_eq!(strings(&parse_ok(&out)), before);
    }
}

// L02-T13
#[test]
fn l02_t13_source_hash() {
    let hash = source_hash(LUMEN).unwrap();
    assert_eq!(hash, LUMEN_HASH);
    assert_eq!(source_hash(LUMEN_MESSY).unwrap(), hash);
    assert_eq!(source_hash(&LUMEN.replace('\n', "\r\n")).unwrap(), hash);

    let reworded = LUMEN.replace("# Lumen Studio", "# Lumen Studios");
    assert_ne!(source_hash(&reworded).unwrap(), hash);
    let added = LUMEN.replace("    seats: 3\n", "    seats: 3 # three\n");
    assert_ne!(source_hash(&added).unwrap(), hash);

    let hex = hash.strip_prefix("sha256:").unwrap();
    assert_eq!(hex.len(), 64);
    assert!(
        hex.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    );
}

// L02 extra: every production, written compactly, formats to the canonical layout.
#[test]
fn l02_every_production_formats_canonically() {
    let src = "# file comment\norg \"Kitchen\"{ # open\npurpose \"All of it.\" members:open() members:invite(sponsors:12) amend:approve(core,2)within 30m else allow\ncircle core{seats:2000 term:52w holders:@mina,@jo-2,@x_y}\nagent bot{operator:@mina runtime:byo}\ngoal g \"G\"{steward:core fund:usd 0.500000 once from treasury on_underfunded:continue on_close:transfer h\nsuccess:metric(errors)< - 0.250 success:metric(m2)==7\nmandate @jo{spend expense<=usd 1000000.000001/week spend llm<=usd 9007199254.740991/day can:create_tasks expires:2999-12-31}\nmandate bot{\n}\nrule spend llm>usd 1000 requires vote(members,60%)within 1y else allow rule spend>usd 0.01 requires approve(members,1)}\ngoal h \"H\"{steward:core fund:usd 10/week from treasury on_close:return treasury}}\n# end of file";
    let want = "# file comment
org \"Kitchen\" { # open
  purpose \"All of it.\"
  members: open()
  members: invite(sponsors: 12)
  amend: approve(core, 2) within 30m else allow

  circle core {
    seats: 2_000
    term: 52w
    holders: @mina, @jo-2, @x_y
  }

  agent bot {
    operator: @mina
    runtime: byo
  }

  goal g \"G\" {
    steward: core
    fund: usd 0.50 once from treasury
    on_underfunded: continue
    on_close: transfer h
    success: metric(errors) < -0.250
    success: metric(m2) == 7

    mandate @jo {
      spend expense <= usd 1_000_000.000001 / week
      spend llm <= usd 9_007_199_254.740991 / day
      can: create_tasks
      expires: 2999-12-31
    }

    mandate bot {}

    rule spend llm > usd 1_000 requires vote(members, 60%) within 1y else allow
    rule spend > usd 0.01 requires approve(members, 1)
  }

  goal h \"H\" {
    steward: core
    fund: usd 10 / week from treasury
    on_close: return treasury
  }
}
# end of file
";
    assert_eq!(fmt_ok(src), want);
    assert_eq!(fmt_ok(want), want);
    assert_eq!(
        ast_json_no_trivia(&parse_ok(want)),
        ast_json_no_trivia(&parse_ok(src))
    );
}

// L02 extra: an empty block prints as `{}`; with comments it spans lines.
#[test]
fn l02_empty_blocks() {
    let out = fmt_ok(&goal_with("    mandate @jo {\n\n    }"));
    assert!(has_line(&out, "mandate @jo {}"), "{out}");
    let out = fmt_ok(&goal_with("    mandate @jo { # open\n    }"));
    assert!(out.contains("\n    mandate @jo { # open\n    }\n"), "{out}");
    let out = fmt_ok(&goal_with("    mandate @jo {\n # inside\n }"));
    assert!(
        out.contains("\n    mandate @jo {\n      # inside\n    }\n"),
        "{out}"
    );
}

// L02 extra: durations and dates are not grouped; durations drop leading zeros.
#[test]
fn l02_durations_and_dates() {
    let out = fmt_ok(&circle_with("    term: 007d"));
    assert!(has_line(&out, "term: 7d"), "{out}");
    let out = fmt_ok(&org_with(
        "  goal g \"G\" {\n    rule close requires approve(core, 1) within 36_500d else deny\n  }",
    ));
    let line = "rule close requires approve(core, 1) within 36500d else deny";
    assert!(has_line(&out, line), "{out}");
}

// L02 extra (OQ-9): a metric value loses the leading zeros of its integer part, so
// `010` and `10` format (and hash) the same; its fraction digits are kept as written,
// because the AST keeps them as text (`Signed`).
#[test]
fn l02_metric_values_drop_leading_zeros() {
    for (input, want) in [
        ("0010000", "10_000"),
        ("010", "10"),
        ("000", "0"),
        ("-007.50", "-7.50"),
        ("00.25", "0.25"),
        ("-0", "-0"),
        ("12.50", "12.50"),
        ("1.000", "1.000"),
    ] {
        let out = fmt_ok(&goal_with(&format!("    success: metric(m) == {input}")));
        let line = format!("success: metric(m) == {want}");
        assert!(has_line(&out, &line), "{input} → {want}:\n{out}");
    }
    let hash = |n: &str| source_hash(&goal_with(&format!("    success: metric(m) >= {n}")));
    assert_eq!(hash("010").unwrap(), hash("10").unwrap());
}

// L02 extra: counts keep their value; leading zeros and threshold numbers are normalized.
#[test]
fn l02_counts_and_thresholds() {
    let out = fmt_ok(&org_with("  members: invite(sponsors: 0_02)"));
    assert!(has_line(&out, "members: invite(sponsors: 2)"), "{out}");
    let src = org_with(
        "  goal g \"G\" {\n    rule close requires vote( core , 1000 / 3000 )\n    rule spend requires vote(members,100 %)\n  }",
    );
    let out = fmt_ok(&src);
    assert!(
        has_line(&out, "rule close requires vote(core, 1_000/3_000)"),
        "{out}"
    );
    assert!(
        has_line(&out, "rule spend requires vote(members, 100%)"),
        "{out}"
    );
}

// L02 extra: a source under the size limit whose canonical form is over it is not
// formatted (E109), so formatted output always parses again.
#[test]
fn l02_formatted_source_over_the_size_limit_is_e109() {
    let holders: Vec<String> = (0..31_000).map(|i| format!("@h{i}")).collect();
    let src = circle_with(&format!("    holders:{}", holders.join(",")));
    assert!(
        src.len() <= MAX_SOURCE_BYTES,
        "input is {} bytes",
        src.len()
    );
    assert!(src.len() + holders.len() > MAX_SOURCE_BYTES);
    assert!(parse(&src).diagnostics.is_empty());

    let err = format(&src).unwrap_err();
    let codes: Vec<Code> = err.iter().map(|d| d.code).collect();
    assert_eq!(codes, [Code::E109]);
    assert!(source_hash(&src).is_err());
}

// L02 extra: `rule_line` is the rule's formatted line without comments, the canonical text
// that rule ids hash (SPEC-01 §4.6).
#[test]
fn l02_rule_line_is_the_formatted_rule() {
    let src = goal_with(
        "    rule spend   llm>usd 1000.5 requires vote( members ,60% ) within 48h else allow # why",
    );
    let f = parse_ok(&src);
    let GoalItem::Rule(rule) = last_goal_item(&f) else {
        panic!("expected a rule")
    };
    let line = rule_line(rule);
    assert_eq!(
        line,
        "rule spend llm > usd 1_000.50 requires vote(members, 60%) within 48h else allow"
    );
    assert!(has_line(&fmt_ok(&src), &format!("{line} # why")));
}
