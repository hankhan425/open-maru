//! L04 formatting helpers (`maru_core::human`) and the shared vectors in
//! `tests/vectors/human.json`, which the web app's formatters read too (F01).
//!
//! The vectors file is generated from [`cases`] by the helpers themselves. After a
//! deliberate change, regenerate it with
//! `UPDATE_VECTORS=1 cargo test -p maru_core --test human` and review the diff.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use maru_core::human::{date, duration, list, money, number, threshold};
use maru_core::ir::{DurationUnit, Threshold};
use serde::Serialize;

const VECTORS_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/human.json");

// L04-T02
#[test]
fn l04_t02_money() {
    for (micros, text) in [
        (12_000_000_000, "$12,000"),
        (12_500_000, "$12.50"),
        (125, "$0.000125"),
        (1_000_000, "$1"),
        (1_234_567_890, "$1,234.56789"),
        (10, "$0.00001"),
        (999_999_999_999, "$999,999.999999"),
    ] {
        assert_eq!(money(micros), text, "money({micros})");
    }
}

// L04-T02 (edge cases)
#[test]
fn l04_money_edges() {
    for (micros, text) in [
        (0, "$0"),
        (1, "$0.000001"),
        (100_000, "$0.10"),
        (999_000, "$0.999"),
        (1_000_001, "$1.000001"),
        (1_500_000, "$1.50"),
        (25_000_000, "$25"),
        (999_000_000, "$999"),
        (1_000_000_000, "$1,000"),
        (1_000_000_000_000, "$1,000,000"),
        (9_007_199_254_740_991, "$9,007,199,254.740991"),
        (u64::MAX, "$18,446,744,073,709.551615"),
    ] {
        assert_eq!(money(micros), text, "money({micros})");
    }
}

// L04-T03
#[test]
fn l04_t03_durations() {
    use DurationUnit::*;
    for (value, unit, text) in [
        (30, Minutes, "30 minutes"),
        (1, Minutes, "1 minute"),
        (1, Hours, "1 hour"),
        (48, Hours, "48 hours"),
        (1, Days, "1 day"),
        (7, Days, "7 days"),
        (2, Weeks, "2 weeks"),
        (1, Years, "1 year"),
    ] {
        assert_eq!(duration(value, unit), text, "duration({value}, {unit:?})");
    }
}

// L04-T03 (edge cases)
#[test]
fn l04_durations_plural_and_grouped() {
    use DurationUnit::*;
    assert_eq!(duration(1, Weeks), "1 week");
    assert_eq!(duration(2, Years), "2 years");
    assert_eq!(duration(100, Years), "100 years");
    assert_eq!(duration(36_500, Days), "36,500 days");
    assert_eq!(duration(5_214, Weeks), "5,214 weeks");
    assert_eq!(duration(52_560_000, Minutes), "52,560,000 minutes");
}

// L04-T04
#[test]
fn l04_t04_dates() {
    assert_eq!(date("2027-06-30"), "June 30, 2027");
    assert_eq!(date("2027-01-01"), "January 1, 2027");
}

// L04-T04 (edge cases)
#[test]
fn l04_dates_every_month_and_invalid_input() {
    let months = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    for (i, name) in months.iter().enumerate() {
        assert_eq!(
            date(&format!("2030-{:02}-09", i + 1)),
            format!("{name} 9, 2030")
        );
    }
    assert_eq!(date("2000-02-29"), "February 29, 2000");
    assert_eq!(date("2999-12-31"), "December 31, 2999");
    // Not a date in `YYYY-MM-DD` form: returned unchanged.
    for s in [
        "",
        "2027-02-30",
        "2027-13-01",
        "2027-6-30",
        "2027-06-30T00:00:00Z",
        "27-06-30",
        "June",
    ] {
        assert_eq!(date(s), s);
    }
}

// L04-T05
#[test]
fn l04_t05_lists() {
    assert_eq!(list(&["a"]), "a");
    assert_eq!(list(&["a", "b"]), "a and b");
    assert_eq!(list(&["a", "b", "c"]), "a, b, and c");
}

// L04-T05 (edge cases)
#[test]
fn l04_lists_empty_and_long() {
    assert_eq!(list::<&str>(&[]), "");
    assert_eq!(list(&["a", "b", "c", "d"]), "a, b, c, and d");
    let owned: Vec<String> = vec!["x".into(), "y".into()];
    assert_eq!(list(&owned), "x and y");
}

// L04-T06
#[test]
fn l04_t06_thresholds() {
    for (num, den, percent, text) in [
        (1, 2, false, "half"),
        (1, 3, false, "one-third"),
        (2, 3, false, "two-thirds"),
        (3, 4, false, "three-quarters"),
        (3, 5, false, "3/5"),
        (2, 4, false, "2/4"),
        (60, 100, true, "60%"),
    ] {
        assert_eq!(threshold(num, den, percent), text, "{num}/{den} {percent}");
    }
}

// L04-T06 (edge cases): only the form as written matters.
#[test]
fn l04_thresholds_as_written() {
    assert_eq!(threshold(50, 100, true), "50%");
    assert_eq!(threshold(100, 100, true), "100%");
    assert_eq!(threshold(1, 100, true), "1%");
    assert_eq!(threshold(50, 100, false), "50/100");
    assert_eq!(threshold(2, 6, false), "2/6");
    assert_eq!(threshold(1, 1, false), "1/1");
    assert_eq!(threshold(1_000, 3_000, false), "1,000/3,000");
}

// L04 extra: `number` for metric values (L04-T13 uses it).
#[test]
fn l04_number_groups_the_integer_part_only() {
    for (input, text) in [
        ("0", "0"),
        ("999", "999"),
        ("1000", "1,000"),
        ("10000", "10,000"),
        ("-0.5", "-0.5"),
        ("-1500.5", "-1,500.5"),
        ("12.50", "12.50"),
        ("1234567.891", "1,234,567.891"),
        ("0.0001234", "0.0001234"),
        ("-1000000", "-1,000,000"),
        (
            "123456789012345678901234567890",
            "123,456,789,012,345,678,901,234,567,890",
        ),
    ] {
        assert_eq!(number(input), text, "number({input:?})");
    }
    // Not a decimal: returned unchanged.
    for s in [
        "", "-", "1.", ".5", "1_000", "+5", "1e3", "12a", "1.2.3", "--1",
    ] {
        assert_eq!(number(s), s);
    }
}

// ---- shared vectors (L04-T19) ----

#[derive(Serialize)]
struct Case<I: Serialize> {
    input: I,
    output: String,
}

#[derive(Serialize)]
struct DurationInput {
    value: u64,
    unit: DurationUnit,
}

/// The inputs of every vector, in file order. Outputs come from the helpers.
struct Inputs {
    money: Vec<u64>,
    number: Vec<&'static str>,
    duration: Vec<(u64, DurationUnit)>,
    date: Vec<&'static str>,
    list: Vec<Vec<&'static str>>,
    threshold: Vec<(u32, u32, bool)>,
}

fn cases() -> Inputs {
    use DurationUnit::*;
    Inputs {
        money: vec![
            12_000_000_000,
            12_500_000,
            125,
            1_000_000,
            1_234_567_890,
            10,
            999_999_999_999,
            0,
            1,
            100_000,
            999_000,
            1_000_001,
            1_500_000,
            25_000_000,
            500_000_000,
            1_000_000_000,
            4_000_000_000,
            5_000_000_000,
            1_000_000_000_000,
            9_007_199_254_740_991,
        ],
        number: vec![
            "0",
            "999",
            "1000",
            "10000",
            "-0.5",
            "-1500.5",
            "12.50",
            "1234567.891",
            "0.0001234",
            "-1000000",
            "123456789012345678901234567890",
        ],
        duration: vec![
            (30, Minutes),
            (1, Minutes),
            (1, Hours),
            (48, Hours),
            (1, Days),
            (7, Days),
            (1, Weeks),
            (2, Weeks),
            (1, Years),
            (2, Years),
            (36_500, Days),
        ],
        date: vec![
            "2027-06-30",
            "2027-01-01",
            "2000-02-29",
            "2026-03-09",
            "2999-12-31",
        ],
        list: vec![
            vec!["a"],
            vec!["a", "b"],
            vec!["a", "b", "c"],
            vec!["claim tasks", "create tasks", "post evidence", "report m"],
        ],
        threshold: vec![
            (1, 2, false),
            (1, 3, false),
            (2, 3, false),
            (3, 4, false),
            (3, 5, false),
            (2, 4, false),
            (1, 1, false),
            (1_000, 3_000, false),
            (60, 100, true),
            (100, 100, true),
            (50, 100, false),
        ],
    }
}

/// One JSON object per line within each group, so diffs show the changed vectors.
fn group<I: Serialize>(name: &str, cases: Vec<Case<I>>, out: &mut Vec<String>) {
    let lines: Vec<String> = cases
        .iter()
        .map(|c| format!("    {}", serde_json::to_string(c).unwrap()))
        .collect();
    out.push(format!("  \"{name}\": [\n{}\n  ]", lines.join(",\n")));
}

/// The contents of `tests/vectors/human.json`, computed by the helpers.
fn generate() -> String {
    let inputs = cases();
    let mut groups = vec![format!(
        "  \"generated_by\": {}",
        serde_json::to_string(
            "crates/maru_core/tests/human.rs (L04-T19); regenerate with \
             UPDATE_VECTORS=1 cargo test -p maru_core --test human"
        )
        .unwrap()
    )];
    group(
        "money",
        inputs
            .money
            .into_iter()
            .map(|m| Case {
                input: m.to_string(),
                output: money(m),
            })
            .collect(),
        &mut groups,
    );
    group(
        "number",
        inputs
            .number
            .into_iter()
            .map(|n| Case {
                input: n,
                output: number(n),
            })
            .collect(),
        &mut groups,
    );
    group(
        "duration",
        inputs
            .duration
            .into_iter()
            .map(|(value, unit)| Case {
                input: DurationInput { value, unit },
                output: duration(value, unit),
            })
            .collect(),
        &mut groups,
    );
    group(
        "date",
        inputs
            .date
            .into_iter()
            .map(|d| Case {
                input: d,
                output: date(d),
            })
            .collect(),
        &mut groups,
    );
    group(
        "list",
        inputs
            .list
            .into_iter()
            .map(|items| Case {
                output: list(&items),
                input: items,
            })
            .collect(),
        &mut groups,
    );
    group(
        "threshold",
        inputs
            .threshold
            .into_iter()
            .map(|(num, den, percent)| Case {
                input: Threshold { num, den, percent },
                output: threshold(num, den, percent),
            })
            .collect(),
        &mut groups,
    );
    format!("{{\n{}\n}}\n", groups.join(",\n"))
}

// L04-T19
#[test]
fn l04_t19_human_vectors_match_the_helpers() {
    let generated = generate();
    if std::env::var_os("UPDATE_VECTORS").is_some() {
        std::fs::write(VECTORS_PATH, &generated).unwrap();
    }
    let committed = std::fs::read_to_string(VECTORS_PATH)
        .unwrap_or_else(|e| panic!("reading {VECTORS_PATH}: {e}"));
    assert!(
        committed == generated,
        "tests/vectors/human.json is out of date with the helpers; regenerate it with \
         UPDATE_VECTORS=1 cargo test -p maru_core --test human and review the diff"
    );
}

// L04-T19: consumers read the file as plain JSON; every group is a list of
// `{input, output}` objects, and money inputs are strings of micros (CONVENTIONS §4).
#[test]
fn l04_t19_human_vectors_are_plain_json_with_the_listed_cases() {
    let text = std::fs::read_to_string(VECTORS_PATH).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    let pairs = |group: &str| -> Vec<(serde_json::Value, String)> {
        v[group]
            .as_array()
            .unwrap_or_else(|| panic!("group {group}"))
            .iter()
            .map(|c| {
                (
                    c["input"].clone(),
                    c["output"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };
    let has = |group: &str, input: serde_json::Value, output: &str| {
        assert!(
            pairs(group).contains(&(input.clone(), output.to_string())),
            "{group}: {input} → {output}"
        );
    };
    use serde_json::json;
    has("money", json!("12000000000"), "$12,000");
    has("money", json!("999999999999"), "$999,999.999999");
    has("duration", json!({"value": 48, "unit": "h"}), "48 hours");
    has("date", json!("2027-06-30"), "June 30, 2027");
    has("list", json!(["a", "b", "c"]), "a, b, and c");
    has(
        "threshold",
        json!({"num": 2, "den": 3, "percent": false}),
        "two-thirds",
    );
    has(
        "threshold",
        json!({"num": 60, "den": 100, "percent": true}),
        "60%",
    );
    has("number", json!("-0.5"), "-0.5");
}
