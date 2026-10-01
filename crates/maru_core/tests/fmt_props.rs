//! L02 property tests: on generated sources with messy layouts the formatter is idempotent,
//! AST-preserving and independent of layout, and it never panics on any input. Failing
//! cases are persisted by proptest under `tests/fmt_props.proptest-regressions` and printed
//! with the shrunk input.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use maru_core::lexer::{Keyword, TokenKind, lex};
use maru_core::{Span, format, parse, source_hash};
use proptest::prelude::*;
use support::strategies::*;
use support::*;

/// Layout choices, consumed in order and cycled. Choice 0 is always the plainest layout,
/// so failures shrink towards simple sources.
struct Choices<'a> {
    values: &'a [u8],
    next: usize,
}

impl Choices<'_> {
    /// A choice in `0..n`.
    fn pick(&mut self, n: usize) -> usize {
        if self.values.is_empty() {
            return 0;
        }
        let v = self.values[self.next % self.values.len()];
        self.next += 1;
        usize::from(v) % n
    }

    fn one_of<'s>(&mut self, options: &[&'s str]) -> &'s str {
        options[self.pick(options.len())]
    }
}

fn layout() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(any::<u8>(), 0..64)
}

/// Whitespace between two tokens on the same item.
const ANY_GAP: &[&str] = &[
    " ", "  ", "\t", "\n", "\n\n", "\n    ", " \n\t\t", "\n\n\n  ", " \t ",
];
/// Whitespace that must contain a line break (after a comment, or before a comment that
/// was on its own line).
const LINE_GAP: &[&str] = &["\n", "\n\n", "\n  ", "   \n\t", "\n\n\n", "\t\n      "];
/// Whitespace that must not contain a line break (before a trailing comment).
const INLINE_GAP: &[&str] = &[" ", "", "   ", "\t"];
const PREFIX: &[&str] = &["", "\n", "  ", "\n\n\t"];
const SUFFIX: &[&str] = &["\n", "", "\n\n\n", "  \n", "\n \t"];

/// Tokens that never merge with a neighbour when written without a space.
fn touches(kind: &TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::LBrace
            | TokenKind::RBrace
            | TokenKind::LParen
            | TokenKind::RParen
            | TokenKind::Colon
            | TokenKind::Comma
            | TokenKind::Slash
            | TokenKind::Percent
            | TokenKind::Minus
    )
}

/// `digits` with up to two leading zeros (when `zeros`) and random single `_` separators.
fn regroup(digits: &str, zeros: bool, ch: &mut Choices) -> String {
    let mut s = String::new();
    if zeros {
        s.push_str(ch.one_of(&["", "", "", "0", "00"]));
    }
    s.push_str(digits);
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && ch.pick(4) == 3 {
            out.push('_');
        }
        out.push(c);
    }
    out
}

/// A token's text, rewritten in an equivalent way: numbers regrouped, money and count
/// numbers with leading zeros, money fractions padded with zeros. Metric values (after a
/// comparator or `-`) keep their digits, since the AST keeps them as text.
fn token_text(
    src: &str,
    span: Span,
    kind: &TokenKind,
    prev: Option<&TokenKind>,
    ch: &mut Choices,
) -> String {
    let metric = matches!(
        prev,
        Some(
            TokenKind::Ge
                | TokenKind::Gt
                | TokenKind::Le
                | TokenKind::Lt
                | TokenKind::EqEq
                | TokenKind::Minus
        )
    );
    let money = prev == Some(&TokenKind::Keyword(Keyword::Usd));
    match kind {
        TokenKind::Int(digits) => {
            let mut s = regroup(digits, !metric, ch);
            if money && ch.pick(3) == 2 {
                s.push_str(ch.one_of(&[".0", ".00", ".000000"]));
            }
            s
        }
        TokenKind::Decimal { int, frac } => {
            let mut frac = frac.clone();
            if money {
                while frac.len() < 6 && ch.pick(2) == 1 {
                    frac.push('0');
                }
            }
            format!("{}.{frac}", regroup(int, !metric, ch))
        }
        TokenKind::Duration { value, unit } => {
            format!(
                "{}{}",
                regroup(&value.to_string(), true, ch),
                unit.as_char()
            )
        }
        _ => src[span.range()].to_string(),
    }
}

/// Rewrites a valid source with a messy layout and equivalent literals, keeping every
/// comment on its line relative to its neighbours (so comments attach to the same items).
fn messy(src: &str, ch: &mut Choices) -> String {
    let lexed = lex(src);
    let mut pieces: Vec<(Span, Option<&TokenKind>)> = lexed
        .tokens
        .iter()
        .filter(|t| t.kind != TokenKind::Eof)
        .map(|t| (t.span, Some(&t.kind)))
        .chain(lexed.comments.iter().map(|c| (c.span, None)))
        .collect();
    pieces.sort_by_key(|p| p.0.start.offset);

    let mut out = ch.one_of(PREFIX).to_string();
    let mut prev: Option<(Span, Option<&TokenKind>)> = None;
    let mut prev_token: Option<&TokenKind> = None;
    for &(span, kind) in &pieces {
        if let Some((prev_span, prev_kind)) = prev {
            let gap = &src[prev_span.end.offset..span.start.offset];
            let ws = match (prev_kind, kind) {
                (None, _) => ch.one_of(LINE_GAP),
                (_, None) if gap.contains('\n') => ch.one_of(LINE_GAP),
                (_, None) => ch.one_of(INLINE_GAP),
                (Some(a), Some(b)) if touches(a) || touches(b) => {
                    if ch.pick(4) == 0 {
                        ""
                    } else {
                        ch.one_of(ANY_GAP)
                    }
                }
                (Some(_), Some(_)) => ch.one_of(ANY_GAP),
            };
            out.push_str(ws);
        }
        match kind {
            Some(kind) => {
                out.push_str(&token_text(src, span, kind, prev_token, ch));
                prev_token = Some(kind);
            }
            None => {
                out.push_str(&src[span.range()]);
                out.push_str(ch.one_of(&["", " ", "\t ", "   "]));
            }
        }
        prev = Some((span, kind));
    }
    out.push_str(ch.one_of(SUFFIX));
    if ch.pick(3) == 2 {
        out = out.replace('\n', "\r\n");
    }
    out
}

/// A generated valid source with a messy layout.
fn messy_source(f: &maru_core::ast::File, layout: &[u8]) -> String {
    messy(
        &printer::file(f),
        &mut Choices {
            values: layout,
            next: 0,
        },
    )
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1_000))]

    // L02-T09
    #[test]
    fn l02_t09_format_is_idempotent(f in file(), layout in layout()) {
        let src = messy_source(&f, &layout);
        let once = format(&src);
        prop_assert!(once.is_ok(), "{:#?}\nfor source:\n{}", once, src);
        let once = once.unwrap();
        assert_clean_text(&once);
        prop_assert_eq!(format(&once), Ok(once.clone()), "source:\n{}", src);
    }

    // L02-T10
    #[test]
    fn l02_t10_format_preserves_the_ast(f in file(), layout in layout()) {
        let src = messy_source(&f, &layout);
        let before = parse(&src);
        prop_assert!(before.diagnostics.is_empty(), "{:#?}\nfor source:\n{}", before.diagnostics, src);
        let formatted = format(&src).unwrap();
        let after = parse(&formatted);
        prop_assert!(after.diagnostics.is_empty(), "{:#?}\nfor output:\n{}", after.diagnostics, formatted);
        prop_assert_eq!(
            ast_json_no_trivia(&after.file.unwrap()),
            ast_json_no_trivia(&before.file.unwrap()),
            "source:\n{}\noutput:\n{}", src, formatted
        );
    }

    // L02 extra: layout never matters, and comments stay attached to their items (with
    // trailing whitespace trimmed).
    #[test]
    fn l02_layout_is_irrelevant_and_comments_stay_attached(f in file(), layout in layout()) {
        let plain = printer::file(&f);
        let canonical = format(&plain).unwrap();
        let src = messy_source(&f, &layout);
        prop_assert_eq!(format(&src).unwrap(), canonical.clone(), "source:\n{}", src);
        let reparsed = parse(&canonical).file.unwrap();
        prop_assert_eq!(
            ast_json_trimmed_comments(&reparsed),
            ast_json_trimmed_comments(&f),
            "output:\n{}", canonical
        );
    }
}

/// Formats any input without panicking. When it formats, the output is clean, canonical
/// and AST-preserving, and the hash agrees.
fn check_any(src: &str) {
    match format(src) {
        Err(diagnostics) => {
            assert!(
                !diagnostics.is_empty(),
                "error without diagnostics for {src:?}"
            );
            assert!(source_hash(src).is_err());
        }
        Ok(out) => {
            assert_clean_text(&out);
            assert_eq!(format(&out).as_ref(), Ok(&out), "for {src:?}");
            let before = parse(src).file.unwrap();
            let after = parse(&out).file.unwrap();
            assert_eq!(ast_json_no_trivia(&after), ast_json_no_trivia(&before));
            assert!(source_hash(src).is_ok());
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(5_000))]

    // L02 acceptance: the formatter never panics (L01-T21's fuzz inputs).
    #[test]
    fn l02_arbitrary_strings_never_panic(src in any::<String>()) {
        check_any(&src);
    }

    // L02 acceptance
    #[test]
    fn l02_random_bytes_never_panic(bytes in prop::collection::vec(any::<u8>(), 0..1024)) {
        check_any(&String::from_utf8_lossy(&bytes));
    }

    // L02 acceptance
    #[test]
    fn l02_token_soup_never_panics(src in token_soup()) {
        check_any(&src);
        check_any(&format!("org \"T\" {{\n{src}\n}}"));
        check_any(&format!("org \"T\" {{\n goal g \"G\" {{\n{src}\n}}\n}}"));
    }

    // L02 acceptance
    #[test]
    fn l02_mutated_lumen_never_panics(src in mutated_lumen()) {
        check_any(&src);
    }
}
