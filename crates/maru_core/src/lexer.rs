//! Lexer for maru-lang v0 (SPEC-01 §2).
//!
//! The lexer never fails: every lexical error is reported as a [`Diagnostic`] and leaves a
//! [`TokenKind::Error`] token behind, which the parser absorbs without a second
//! diagnostic. Words whose meaning depends on where they appear (a malformed identifier
//! vs. a malformed number or duration) are lexed as [`TokenKind::Word`] and classified by
//! the parser.

use crate::ast::{Comment, DurationUnit};
use crate::diag::Diagnostic;
use crate::span::Span;

macro_rules! keywords {
    ($($name:ident => $text:literal),* $(,)?) => {
        /// A reserved word (SPEC-01 §2).
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum Keyword {
            $(#[doc = concat!("`", $text, "`")] $name,)*
        }

        impl Keyword {
            /// Every keyword, in spec order.
            pub const ALL: &'static [Keyword] = &[$(Keyword::$name,)*];

            /// The keyword as written.
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Keyword::$name => $text,)*
                }
            }

            /// The keyword spelled `word`, if any.
            pub fn from_word(word: &str) -> Option<Keyword> {
                match word {
                    $($text => Some(Keyword::$name),)*
                    _ => None,
                }
            }
        }
    };
}

keywords! {
    Org => "org", Purpose => "purpose", Members => "members", Open => "open",
    Invite => "invite", Sponsors => "sponsors", Amend => "amend", Circle => "circle",
    Seats => "seats", Term => "term", Holders => "holders", Agent => "agent",
    Operator => "operator", Runtime => "runtime", Byo => "byo", Hosted => "hosted",
    Goal => "goal", Steward => "steward", Fund => "fund", From => "from",
    Treasury => "treasury", Once => "once", Success => "success", Metric => "metric",
    By => "by", OnUnderfunded => "on_underfunded", Pause => "pause", Continue => "continue",
    OnClose => "on_close", Return => "return", Transfer => "transfer", Mandate => "mandate",
    Spend => "spend", PerRequest => "per_request", Can => "can", Expires => "expires",
    ClaimTasks => "claim_tasks", CreateTasks => "create_tasks",
    PostEvidence => "post_evidence", ReportMetric => "report_metric", Rule => "rule",
    Requires => "requires", Approve => "approve", Vote => "vote", Within => "within",
    Else => "else", Deny => "deny", Allow => "allow", Close => "close", Usd => "usd",
    Llm => "llm", Compute => "compute", Expense => "expense", Day => "day",
    Week => "week", Month => "month",
}

/// A token with its span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    /// What was lexed.
    pub kind: TokenKind,
    /// Where it is.
    pub span: Span,
}

/// Token kinds. Numeric payloads keep digits as strings (underscores removed) so the
/// parser can decide how large a value may be in each position.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenKind {
    /// A reserved word.
    Keyword(Keyword),
    /// A valid identifier (`[a-z][a-z0-9_]*`, ≤ 40 chars, not a keyword).
    Ident(String),
    /// Any other run of letters, digits and `_` (e.g. `aB`, `1a`, `12__000`, `7mo`).
    /// `numeric` is true when it looks like a number (starts with a digit, or is `_`
    /// followed by digits and underscores).
    Word {
        /// The word as written.
        text: String,
        /// Whether it looks like a (malformed) number.
        numeric: bool,
    },
    /// `INT`: digits with single `_` between groups; payload has the `_` removed.
    Int(String),
    /// `DECIMAL`: `INT "." [0-9]+`.
    Decimal {
        /// Integer digits, `_` removed.
        int: String,
        /// Fraction digits.
        frac: String,
    },
    /// `DURATION`: `INT` followed by `m`, `h`, `d`, `w` or `y`.
    Duration {
        /// The count.
        value: u64,
        /// The unit.
        unit: DurationUnit,
    },
    /// `DATE`: a valid `YYYY-MM-DD` in 2000–2999.
    Date {
        /// Year.
        year: u16,
        /// Month.
        month: u8,
        /// Day.
        day: u8,
    },
    /// `HANDLE`; payload excludes `@`.
    Handle(String),
    /// `STRING`; payload is unescaped.
    Str(String),
    /// `{`.
    LBrace,
    /// `}`.
    RBrace,
    /// `(`.
    LParen,
    /// `)`.
    RParen,
    /// `:`.
    Colon,
    /// `,`.
    Comma,
    /// `/`.
    Slash,
    /// `%`.
    Percent,
    /// `-`.
    Minus,
    /// `->` (reserved punctuation; no production uses it in v0).
    Arrow,
    /// `<=`.
    Le,
    /// `>=`.
    Ge,
    /// `<`.
    Lt,
    /// `>`.
    Gt,
    /// `==`.
    EqEq,
    /// Text the lexer already reported a diagnostic for.
    Error,
    /// End of input (always the last token).
    Eof,
}

/// The lexer's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexOutput {
    /// Tokens in source order, ending with [`TokenKind::Eof`]. Comments are not tokens.
    pub tokens: Vec<Token>,
    /// Comments in source order.
    pub comments: Vec<Comment>,
    /// Lexical errors (E101–E108).
    pub diagnostics: Vec<Diagnostic>,
}

/// Splits `src` into tokens and comments. Never fails; see the module docs.
pub fn lex(_src: &str) -> LexOutput {
    unimplemented!()
}
