//! Helpers for checker tests (L03). Every IR produced through [`run`] or [`run_at`] is
//! validated against `schema/ir.v1.json` (L03-T29) and the output invariants are asserted:
//! diagnostics sorted by span start, spans inside the source, IR exactly when there is no
//! error (L03-T24, L03-T28, L03-T30).

use std::sync::LazyLock;

use maru_core::{CheckOptions, CheckOutput, Code, Diagnostic, Ir, check};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// `schema/ir.v1.json`, read at run time so a missing or broken schema fails tests
/// rather than the build.
pub static SCHEMA: LazyLock<Value> = LazyLock::new(|| {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/schema/ir.v1.json");
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {path}: {e}"));
    serde_json::from_str(&text).expect("schema is JSON")
});

static VALIDATOR: LazyLock<jsonschema::Validator> =
    LazyLock::new(|| jsonschema::validator_for(&SCHEMA).expect("schema compiles"));

/// The schema's validation errors for `ir`, as strings (empty when valid).
pub fn schema_errors(ir: &Value) -> Vec<String> {
    VALIDATOR
        .iter_errors(ir)
        .map(|e| format!("{} at {}", e, e.instance_path()))
        .collect()
}

/// Asserts `ir` validates against `schema/ir.v1.json` (L03-T29).
pub fn assert_schema_valid(ir: &Value) {
    let errors = schema_errors(ir);
    assert!(
        errors.is_empty(),
        "IR does not match schema/ir.v1.json: {errors:#?}\n{ir:#}"
    );
}

/// Asserts the invariants every check result must satisfy and validates the IR.
pub fn assert_invariants(src: &str, out: &CheckOutput) {
    let offsets: Vec<usize> = out
        .diagnostics
        .iter()
        .map(|d| d.span.start.offset)
        .collect();
    assert!(
        offsets.windows(2).all(|w| w[0] <= w[1]),
        "diagnostics not sorted by span start: {:#?}",
        out.diagnostics
    );
    for d in &out.diagnostics {
        assert!(
            src.get(d.span.range()).is_some(),
            "span {:?} of {} is not inside the source",
            d.span,
            d.code
        );
        assert_eq!(d.severity, d.code.severity(), "severity of {}", d.code);
    }
    let has_error = out.diagnostics.iter().any(Diagnostic::is_error);
    assert_eq!(
        out.ir.is_some(),
        !has_error,
        "IR must be present exactly when there is no error: {:#?}",
        out.diagnostics
    );
    if let Some(ir) = &out.ir {
        assert_schema_valid(&serde_json::to_value(ir).expect("IR serializes"));
    }
}

/// `check(src)` without `now`, with the invariants asserted.
pub fn run(src: &str) -> CheckOutput {
    let out = check(src, &CheckOptions::default());
    assert_invariants(src, &out);
    out
}

/// `check(src)` with `now` set to an RFC 3339 timestamp, with the invariants asserted.
pub fn run_at(src: &str, now: &str) -> CheckOutput {
    let now = now.parse().expect("RFC 3339 timestamp");
    let out = check(src, &CheckOptions { now: Some(now) });
    assert_invariants(src, &out);
    out
}

/// The diagnostic codes, in order.
pub fn check_codes(out: &CheckOutput) -> Vec<Code> {
    out.diagnostics.iter().map(|d| d.code).collect()
}

/// The codes of errors only, in order.
pub fn error_codes(out: &CheckOutput) -> Vec<Code> {
    out.diagnostics
        .iter()
        .filter(|d| d.is_error())
        .map(|d| d.code)
        .collect()
}

/// Asserts `src` checks with exactly the diagnostic codes `expected`, in order.
pub fn assert_codes(src: &str, expected: &[Code]) -> CheckOutput {
    let out = run(src);
    assert_eq!(
        check_codes(&out),
        expected,
        "for source:\n{src}\n{:#?}",
        out.diagnostics
    );
    out
}

/// Asserts `src` yields exactly one diagnostic, with `code`, and returns it.
pub fn only(src: &str, code: Code) -> Diagnostic {
    let out = assert_codes(src, &[code]);
    out.diagnostics[0].clone()
}

/// Asserts `src` checks without any diagnostic and returns its IR.
pub fn ir_ok(src: &str) -> Ir {
    let out = assert_codes(src, &[]);
    out.ir.expect("IR for a clean source")
}

/// [`ir_ok`] as JSON.
pub fn ir_json(src: &str) -> Value {
    serde_json::to_value(ir_ok(src)).expect("IR serializes")
}

/// The source text a diagnostic points at.
pub fn text<'a>(src: &'a str, d: &Diagnostic) -> &'a str {
    &src[d.span.range()]
}

/// The 1-based line and column of the first occurrence of `needle` at or after byte
/// `from` (columns count characters).
pub fn line_col(src: &str, needle: &str, from: usize) -> (usize, usize) {
    let at = from + src[from..].find(needle).expect("needle in source");
    let before = &src[..at];
    let line = before.matches('\n').count() + 1;
    let col = before[before.rfind('\n').map_or(0, |i| i + 1)..]
        .chars()
        .count()
        + 1;
    (line, col)
}

/// Asserts `d` has a note naming the location of the first occurrence of `needle`.
pub fn assert_points_to_first(src: &str, d: &Diagnostic, needle: &str) {
    assert_points_to(src, d, "", needle);
}

/// Asserts `d` has a note naming the location of the first `needle` after the first
/// `anchor`.
pub fn assert_points_to(src: &str, d: &Diagnostic, anchor: &str, needle: &str) {
    let from = src.find(anchor).expect("anchor in source");
    let (line, col) = line_col(src, needle, from);
    let expected = format!("line {line}, column {col}");
    assert!(
        d.notes.iter().any(|n| n.contains(&expected)),
        "{} should have a note pointing to {expected}: {:?}",
        d.code,
        d.notes
    );
}

/// The expected rule id: `<goal>:r_` + first 8 hex chars of SHA-256(`line`).
pub fn rule_id(goal: &str, line: &str) -> String {
    let digest = Sha256::digest(line.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("{goal}:r_{}", &hex[..8])
}

/// Whether `id` matches `^[a-z][a-z0-9_]*:r_[0-9a-f]{8}$`.
pub fn is_rule_id(id: &str) -> bool {
    let Some((goal, hash)) = id.split_once(":r_") else {
        return false;
    };
    let mut chars = goal.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        && hash.len() == 8
        && hash
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

/// A warning-free spec: `amend: approve(core, 1)`; circle `core` (3 seats, @mina and @jo);
/// agent `builder` (operator @mina); `org_extra` org items; then goal `g` stewarded by
/// `core` with a mandate for `builder` (`spend llm <= usd 100 / month`) followed by
/// `goal_extra` goal items.
pub fn spec(org_extra: &str, goal_extra: &str) -> String {
    format!(
        "org \"T\" {{
  amend: approve(core, 1)

  circle core {{
    seats: 3
    holders: @mina, @jo
  }}

  agent builder {{
    operator: @mina
  }}
{org_extra}
  goal g \"G\" {{
    steward: core

    mandate builder {{
      spend llm <= usd 100 / month
    }}
{goal_extra}
  }}
}}
"
    )
}

/// [`spec`] with extra goal items only.
pub fn in_goal(goal_extra: &str) -> String {
    spec("", goal_extra)
}

/// [`spec`] with extra org items only.
pub fn in_org(org_extra: &str) -> String {
    spec(org_extra, "")
}
