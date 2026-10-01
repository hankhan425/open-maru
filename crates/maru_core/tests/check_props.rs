//! L03 property tests: the checker never panics, and its result is the IR exactly when
//! there is no error (L03-T30). Every IR produced is validated against the schema
//! (L03-T29) by `support::checking`. Failing cases are persisted by proptest under
//! `tests/check_props.proptest-regressions` and printed with the shrunk input.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use std::collections::HashSet;

use maru_core::ast::MAX_MONEY_MICROS;
use maru_core::{CheckOptions, CheckOutput, check, parse};
use proptest::prelude::*;
use support::checking::*;
use support::strategies::*;
use support::*;

/// Checks `src` with and without `now`, asserting the invariants of both results and
/// properties of any IR.
fn check_all(src: &str) -> CheckOutput {
    let out = run(src);
    let later = run_at(src, "2030-01-01T00:00:00Z");
    assert_eq!(later.ir, out.ir, "`now` changes only warnings");
    if let Some(ir) = &out.ir {
        for goal in &ir.org.goals {
            assert!(goal.limits.unapproved_monthly_max_micros <= MAX_MONEY_MICROS);
            let ids: HashSet<&str> = goal.rules.iter().map(|r| r.id.as_str()).collect();
            assert_eq!(
                ids.len(),
                goal.rules.len(),
                "rule ids unique in {}",
                goal.id
            );
            for m in &goal.mandates {
                let caps: HashSet<&String> = m.capabilities.iter().collect();
                assert_eq!(
                    caps.len(),
                    m.capabilities.len(),
                    "capabilities deduplicated"
                );
            }
        }
    }
    assert_eq!(
        serde_json::to_string(&check(src, &CheckOptions::default())).unwrap(),
        serde_json::to_string(&out).unwrap(),
        "deterministic"
    );
    out
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    // L03-T30
    #[test]
    fn l03_t30_plausible_specs_never_panic_and_give_ir_xor_errors(f in plausible_file()) {
        let src = printer::file(&f);
        // These specs are syntactically valid, so only semantic diagnostics appear.
        prop_assert!(parse(&src).diagnostics.is_empty(), "source:\n{}", src);
        check_all(&src);
    }

    // L03-T30
    #[test]
    fn l03_t30_random_syntax_trees_never_panic(f in file()) {
        check_all(&printer::file(&f));
    }

    // L03-T30
    #[test]
    fn l03_t30_token_soup_never_panics(src in token_soup()) {
        check_all(&src);
        check_all(&format!("org \"T\" {{\n{src}\n}}"));
        check_all(&format!("org \"T\" {{\n goal g \"G\" {{\n{src}\n}}\n}}"));
    }

    // L03-T30
    #[test]
    fn l03_t30_mutated_lumen_never_panics(src in mutated_lumen()) {
        check_all(&src);
    }
}
