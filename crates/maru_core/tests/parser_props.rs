//! L01 property tests: the lexer and parser never panic, and printed ASTs re-parse to
//! the same AST. Failing cases are persisted by proptest under
//! `tests/parser_props.proptest-regressions` and printed with the shrunk input.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::lexer::lex;
use maru_core::parse;
use proptest::prelude::*;
use support::strategies::*;
use support::*;

fn no_panic(src: &str) {
    let _ = lex(src);
    let out = parse(src);
    for d in &out.diagnostics {
        // Spans are always on character boundaries inside the source.
        assert!(
            src.get(d.span.range()).is_some(),
            "bad span {:?} in {src:?}",
            d.span
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(10_000))]

    // L01-T21
    #[test]
    fn l01_t21_arbitrary_strings_never_panic(src in any::<String>()) {
        no_panic(&src);
    }

    // L01-T21
    #[test]
    fn l01_t21_random_bytes_never_panic(bytes in prop::collection::vec(any::<u8>(), 0..1024)) {
        no_panic(&String::from_utf8_lossy(&bytes));
    }

    // L01-T21
    #[test]
    fn l01_t21_token_soup_never_panics(src in token_soup()) {
        no_panic(&src);
        no_panic(&format!("org \"T\" {{\n{src}\n}}"));
        no_panic(&format!("org \"T\" {{\n goal g \"G\" {{\n{src}\n}}\n}}"));
    }

    // L01-T21
    #[test]
    fn l01_t21_mutated_lumen_never_panics(src in mutated_lumen()) {
        no_panic(&src);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    // L01-T22
    #[test]
    fn l01_t22_printed_asts_reparse_to_equal_asts(f in file()) {
        let src = printer::file(&f);
        let out = parse(&src);
        prop_assert!(out.diagnostics.is_empty(), "diagnostics {:#?}\nfor source:\n{}", out.diagnostics, src);
        let parsed = out.file.expect("file");
        prop_assert_eq!(ast_json(&parsed), ast_json(&f), "source:\n{}", src);
    }
}
