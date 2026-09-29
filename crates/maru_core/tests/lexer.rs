//! L01 lexical tests: keywords, identifiers, handles, numbers, money, durations, dates,
//! thresholds, strings, unexpected characters and columns (SPEC-01 §2).
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::ast::*;
use maru_core::lexer::{Keyword, TokenKind, lex};
use maru_core::{Code, Pos, parse};
use support::*;

/// The reserved words exactly as listed in SPEC-01 §2.
const SPEC_KEYWORDS: &str = "org purpose members open invite sponsors amend circle seats term holders agent operator runtime byo hosted goal steward fund from treasury once success metric by on_underfunded pause continue on_close return transfer mandate spend per_request can expires claim_tasks create_tasks post_evidence report_metric rule requires approve vote within else deny allow close usd llm compute expense day week month";

fn spec_keywords() -> Vec<&'static str> {
    SPEC_KEYWORDS.split_whitespace().collect()
}

// L01-T02
#[test]
fn l01_t02_every_keyword_lexes_as_a_keyword() {
    let words = spec_keywords();
    assert_eq!(words.len(), Keyword::ALL.len(), "keyword table size");
    for w in words {
        let out = lex(w);
        assert!(out.diagnostics.is_empty(), "{w}: {:?}", out.diagnostics);
        let kinds: Vec<_> = out.tokens.iter().map(|t| t.kind.clone()).collect();
        let kw = Keyword::from_word(w).unwrap_or_else(|| panic!("{w} is not a Keyword"));
        assert_eq!(kinds, vec![TokenKind::Keyword(kw), TokenKind::Eof], "{w}");
        assert_eq!(kw.as_str(), w);
    }
}

// L01-T02
#[test]
fn l01_t02_words_containing_keywords_are_identifiers() {
    for w in ["orgs", "org_x", "x_org", "usd1", "d", "m", "members_2"] {
        let out = lex(w);
        assert_eq!(out.tokens[0].kind, TokenKind::Ident(w.to_string()), "{w}");
    }
}

// L01-T02
#[test]
fn l01_t02_keyword_as_circle_agent_or_goal_id_is_e107() {
    for w in spec_keywords() {
        assert_single(
            &org_with(&format!("  circle {w} {{\n    seats: 1\n  }}")),
            Code::E107,
            w,
        );
        assert_single(
            &org_with(&format!("  agent {w} {{\n    operator: @mina\n  }}")),
            Code::E107,
            w,
        );
        assert_single(
            &org_with(&format!("  goal {w} \"G\" {{\n    steward: core\n  }}")),
            Code::E107,
            w,
        );
    }
}

// L01-T03
#[test]
fn l01_t03_valid_identifiers() {
    let forty = "a".repeat(40);
    for id in ["a", "a_1", forty.as_str()] {
        let f = parse_ok(&org_with(&format!("  circle {id} {{\n    seats: 1\n  }}")));
        assert_eq!(circle(&f, id).id.name, id);
        let f = parse_ok(&org_with(&format!(
            "  goal {id} \"G\" {{\n    steward: core\n  }}"
        )));
        assert_eq!(goals(&f)[0].id.name, id);
    }
}

// L01-T03
#[test]
fn l01_t03_invalid_identifiers_are_e107_spanning_the_word() {
    let forty_one = "a".repeat(41);
    for id in [forty_one.as_str(), "A", "aB", "1a", "_a"] {
        assert_single(
            &org_with(&format!("  circle {id} {{\n    seats: 1\n  }}")),
            Code::E107,
            id,
        );
        assert_single(
            &org_with(&format!("  agent {id} {{\n    operator: @mina\n  }}")),
            Code::E107,
            id,
        );
        assert_single(&goal_with(&format!("    steward: {id}")), Code::E107, id);
    }
}

// L01-T04
#[test]
fn l01_t04_valid_handles() {
    let thirty = "b".repeat(30);
    for h in ["mina", "a-b_c", "ab", "0x", thirty.as_str()] {
        let f = parse_ok(&circle_with(&format!("    seats: 1\n    holders: @{h}")));
        let c = circle(&f, "c2");
        let CircleItem::Holders(hs) = &c.body.items[1].node else {
            panic!("expected holders for @{h}");
        };
        assert_eq!(hs[0].name, h);
        let f = parse_ok(&agent_with(&format!("    operator: @{h}")));
        let a = agent(&f, "a2");
        assert!(matches!(&a.body.items[0].node, AgentItem::Operator(o) if o.name == h));
    }
}

// L01-T04
#[test]
fn l01_t04_invalid_handles_are_e106() {
    let thirty_one = format!("@{}", "b".repeat(31));
    for h in ["@a", "@-a", "@Mina", thirty_one.as_str(), "@"] {
        assert_single(
            &circle_with(&format!("    seats: 1\n    holders: {h}")),
            Code::E106,
            h,
        );
        assert_single(&agent_with(&format!("    operator: {h}")), Code::E106, h);
    }
}

fn seats_value(src: &str) -> u64 {
    let f = parse_ok(src);
    match &circle(&f, "c2").body.items[0].node {
        CircleItem::Seats(n) => n.value,
        other => panic!("expected seats, got {other:?}"),
    }
}

fn per_request(src: &str) -> Money {
    let f = parse_ok(src);
    match mandate_items(&f)[0] {
        MandateItem::PerRequest(m) => m.clone(),
        other => panic!("expected per_request, got {other:?}"),
    }
}

// L01-T05
#[test]
fn l01_t05_valid_numbers() {
    for (text, value) in [("0", 0), ("12_000", 12_000), ("1_0", 10), ("7", 7)] {
        assert_eq!(
            seats_value(&circle_with(&format!("    seats: {text}"))),
            value
        );
    }
    let m = per_request(&mandate_with("      per_request <= usd 12.50"));
    assert_eq!(m.micros, 12_500_000);
    let m = per_request(&mandate_with("      per_request <= usd 12_000"));
    assert_eq!(m.micros, 12_000_000_000);
}

// L01 extra (OQ-2): money spelled differently but equal in value gives equal ASTs, so the
// formatter's AST-preservation property holds with only spans and comments ignored.
#[test]
fn l01_money_spellings_of_one_value_give_equal_asts() {
    for (a, b) in [("12000", "12_000"), ("12.5", "12.50"), ("7", "7.000000")] {
        let ast = |n: &str| {
            ast_json(&parse_ok(&mandate_with(&format!(
                "      per_request <= usd {n}"
            ))))
        };
        assert_eq!(ast(a), ast(b), "usd {a} vs usd {b}");
    }
}

// L01-T05
#[test]
fn l01_t05_malformed_numbers_are_e103() {
    for n in ["12__000", "_12", "12_", "1._5"] {
        assert_single(&circle_with(&format!("    seats: {n}")), Code::E103, n);
        assert_single(
            &mandate_with(&format!("      per_request <= usd {n}")),
            Code::E103,
            n,
        );
    }
}

// L01-T06
#[test]
fn l01_t06_money_with_seven_decimals_is_e311() {
    assert_single(
        &mandate_with("      per_request <= usd 1.1234567"),
        Code::E311,
        "1.1234567",
    );
    assert_single(
        &mandate_with("      spend llm <= usd 0.0000001 / month"),
        Code::E311,
        "0.0000001",
    );
}

// L01-T06
#[test]
fn l01_t06_six_decimals_are_exact_micros() {
    assert_eq!(
        per_request(&mandate_with("      per_request <= usd 0.000001")).micros,
        1
    );
    assert_eq!(
        per_request(&mandate_with("      per_request <= usd 1.123456")).micros,
        1_123_456
    );
    assert_eq!(
        per_request(&mandate_with("      per_request <= usd 3.000100")).micros,
        3_000_100
    );
}

fn circle_term(src: &str) -> Duration {
    let f = parse_ok(src);
    match &circle(&f, "c2").body.items[1].node {
        CircleItem::Term(d) => d.clone(),
        other => panic!("expected term, got {other:?}"),
    }
}

// L01-T07
#[test]
fn l01_t07_durations_keep_value_and_unit() {
    for (text, value, unit, secs) in [
        ("30m", 30, DurationUnit::Minutes, 1_800),
        ("48h", 48, DurationUnit::Hours, 172_800),
        ("7d", 7, DurationUnit::Days, 604_800),
        ("2w", 2, DurationUnit::Weeks, 1_209_600),
        ("1y", 1, DurationUnit::Years, 31_536_000),
    ] {
        let d = circle_term(&circle_with(&format!("    seats: 1\n    term: {text}")));
        assert_eq!((d.value, d.unit, d.secs()), (value, unit, secs), "{text}");
    }
}

// L01-T07
#[test]
fn l01_t07_malformed_durations_are_e104() {
    for d in ["7x", "7mo", "7", "1.5d", "7 d"] {
        let first = d.split(' ').next().unwrap_or(d);
        let out = parse(&circle_with(&format!("    seats: 1\n    term: {d}")));
        assert_eq!(codes(&out)[0], Code::E104, "{d}: {:?}", out.diagnostics);
        assert_eq!(
            slice(
                &circle_with(&format!("    seats: 1\n    term: {d}")),
                out.diagnostics[0].span
            ),
            first
        );
    }
    for d in ["7x", "7mo"] {
        assert_single(
            &circle_with(&format!("    seats: 1\n    term: {d}")),
            Code::E104,
            d,
        );
        assert_single(
            &goal_with(&format!(
                "    rule close requires approve(core, 1) within {d} else deny"
            )),
            Code::E104,
            d,
        );
    }
}

// L01 extra (OQ-4): durations longer than 100 years are malformed durations.
#[test]
fn l01_duration_above_maximum_is_e104() {
    for d in ["100y", "36500d", "876000h", "52560000m", "5214w"] {
        let src = circle_with(&format!("    seats: 1\n    term: {d}"));
        assert!(circle_term(&src).secs() <= MAX_DURATION_SECS, "{d}");
    }
    for d in [
        "101y",
        "36501d",
        "876001h",
        "52560001m",
        "5215w",
        "99999999999999999999y",
    ] {
        assert_single(
            &circle_with(&format!("    seats: 1\n    term: {d}")),
            Code::E104,
            d,
        );
    }
}

fn expires(src: &str) -> Date {
    let f = parse_ok(src);
    match mandate_items(&f)[0] {
        MandateItem::Expires(d) => d.clone(),
        other => panic!("expected expires, got {other:?}"),
    }
}

// L01-T08
#[test]
fn l01_t08_valid_dates() {
    for (text, ymd) in [
        ("2027-06-30", (2027, 6, 30)),
        ("2028-02-29", (2028, 2, 29)),
        ("2000-01-01", (2000, 1, 1)),
        ("2999-12-31", (2999, 12, 31)),
    ] {
        let d = expires(&mandate_with(&format!("      expires: {text}")));
        assert_eq!((d.year, d.month, d.day), ymd);
        assert_eq!(d.to_iso(), text);
    }
}

// L01-T08
#[test]
fn l01_t08_invalid_dates_are_e105() {
    for d in [
        "2027-02-29",
        "2027-13-01",
        "1999-01-01",
        "3000-01-01",
        "2027-6-30",
        "2027-00-10",
        "2027-04-31",
        "2100-02-29",
    ] {
        assert_single(&mandate_with(&format!("      expires: {d}")), Code::E105, d);
        assert_single(
            &goal_with(&format!("    success: metric(wau) >= 1 by {d}")),
            Code::E105,
            d,
        );
    }
}

fn close_rule_threshold(src: &str) -> Threshold {
    let f = parse_ok(src);
    match last_goal_item(&f) {
        GoalItem::Rule(Rule {
            procedure:
                Procedure {
                    kind: ProcedureKind::Vote { threshold, .. },
                    ..
                },
            ..
        }) => threshold.clone(),
        other => panic!("expected a vote rule, got {other:?}"),
    }
}

// L01-T09
#[test]
fn l01_t09_thresholds_parse_to_fractions() {
    for (text, fraction, percent) in [
        ("2/3", (2, 3), false),
        ("2 / 3", (2, 3), false),
        ("60%", (60, 100), true),
    ] {
        let t = close_rule_threshold(&goal_with(&format!(
            "    rule close requires vote(core, {text})"
        )));
        assert_eq!(t.as_fraction(), fraction, "{text}");
        assert_eq!(
            matches!(t.kind, ThresholdKind::Percent { .. }),
            percent,
            "{text}"
        );
    }
    let t = close_rule_threshold(&goal_with("    rule close requires vote(core, 2/4)"));
    assert!(matches!(
        t.kind,
        ThresholdKind::Fraction { ref num, ref den } if num.value == 2 && den.value == 4
    ));
}

// L01-T09
#[test]
fn l01_t09_threshold_range_is_not_checked_by_the_parser() {
    for text in ["0/3", "4/3", "1/0", "0%", "101%"] {
        parse_ok(&goal_with(&format!(
            "    rule close requires vote(core, {text})"
        )));
    }
}

fn org_purpose(src: &str) -> String {
    let f = parse_ok(src);
    match last_org_item(&f) {
        OrgItem::Purpose(s) => s.value.clone(),
        other => panic!("expected purpose, got {other:?}"),
    }
}

// L01-T10
#[test]
fn l01_t10_string_escapes_are_decoded() {
    let v = org_purpose(&org_with(r#"  purpose "say \"hi\" \\ then\nbye""#));
    assert_eq!(v, "say \"hi\" \\ then\nbye");
    assert_eq!(
        org_purpose(&org_with(r#"  purpose "é🦀 # not a comment""#)),
        "é🦀 # not a comment"
    );
}

// L01-T10
#[test]
fn l01_t10_unterminated_string_is_e102() {
    let src = "org \"T\" {\n  amend: approve(core, 1)\n  purpose \"abc\n}\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E102], "{:#?}", out.diagnostics);
    let offset = src.find("\"abc").expect("quote");
    assert_eq!(
        out.diagnostics[0].span.start,
        Pos {
            line: 3,
            col: 11,
            offset
        }
    );
    // The span stays on the line where the string starts.
    assert_eq!(slice(src, out.diagnostics[0].span), "\"abc");
    let out = parse("org \"T");
    assert_eq!(codes(&out), vec![Code::E102], "{:#?}", out.diagnostics);
}

// L01-T10
#[test]
fn l01_t10_raw_newline_in_string_is_e108() {
    let src = org_with("  purpose \"ab\ncd\"");
    assert_single(&src, Code::E108, "\"ab\ncd\"");
}

// L01-T10
#[test]
fn l01_t10_string_length_limit_is_500_chars_after_unescaping() {
    let ok = "a".repeat(500);
    assert_eq!(org_purpose(&org_with(&format!("  purpose \"{ok}\""))), ok);
    let ok_wide = "é".repeat(500);
    assert_eq!(
        org_purpose(&org_with(&format!("  purpose \"{ok_wide}\""))),
        ok_wide
    );
    let ok_escaped = format!("{}\\n", "a".repeat(499));
    assert_eq!(
        org_purpose(&org_with(&format!("  purpose \"{ok_escaped}\"")))
            .chars()
            .count(),
        500
    );

    let long = format!("\"{}\"", "a".repeat(501));
    assert_single(&org_with(&format!("  purpose {long}")), Code::E108, &long);
    let long_escaped = format!("\"{}\\\"\"", "a".repeat(500));
    assert_single(
        &org_with(&format!("  purpose {long_escaped}")),
        Code::E108,
        &long_escaped,
    );
}

// L01-T12
#[test]
fn l01_t12_dollar_is_e101_with_exact_position() {
    let src = "org \"T\" {\n  amend: approve(core, 1)\n  purpose $\"x\"\n}\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E101], "{:#?}", out.diagnostics);
    let span = out.diagnostics[0].span;
    let offset = src.find('$').expect("$");
    assert_eq!(
        span.start,
        Pos {
            line: 3,
            col: 11,
            offset
        }
    );
    assert_eq!(
        span.end,
        Pos {
            line: 3,
            col: 12,
            offset: offset + 1
        }
    );
    assert_eq!(slice(src, span), "$");
}

// L01-T12
#[test]
fn l01_t12_semicolon_is_e101_with_exact_position() {
    let src = "org \"T\" {\n  amend: approve(core, 1);\n  purpose \"x\"\n}\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E101], "{:#?}", out.diagnostics);
    let span = out.diagnostics[0].span;
    let offset = src.find(';').expect(";");
    assert_eq!(
        span.start,
        Pos {
            line: 2,
            col: 26,
            offset
        }
    );
    assert_eq!(slice(src, span), ";");
    // The amend before `;` and the purpose after it both survive.
    let f = out.file.expect("file");
    assert_eq!(f.org.node.body.items.len(), 2);
}

// L01-T13
#[test]
fn l01_t13_columns_count_unicode_scalars() {
    let src = "org \"T\" {\n  purpose \"é🦀\" $\n  amend: approve(core, 1)\n}\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E101], "{:#?}", out.diagnostics);
    let span = out.diagnostics[0].span;
    // `  purpose "é🦀" $`: 2 spaces, `purpose`, space, 4 scalars of string, space → col 16.
    assert_eq!(span.start.line, 2);
    assert_eq!(span.start.col, 16);
    assert_eq!(span.end.col, 17);
    assert_eq!(slice(src, span), "$");

    // Same for a parser error after multi-byte text.
    let src = "org \"T\" {\n  purpose \"é🦀\" 5\n  amend: approve(core, 1)\n}\n";
    let out = parse(src);
    assert_eq!(codes(&out), vec![Code::E201], "{:#?}", out.diagnostics);
    assert_eq!(
        (
            out.diagnostics[0].span.start.line,
            out.diagnostics[0].span.start.col
        ),
        (2, 16)
    );
}
