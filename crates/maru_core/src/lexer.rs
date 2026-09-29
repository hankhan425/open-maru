//! Lexer for maru-lang v0 (SPEC-01 §2).
//!
//! The lexer never fails: every lexical error is reported as a [`Diagnostic`] and leaves a
//! [`TokenKind::Error`] token behind, which the parser absorbs without a second
//! diagnostic. Words whose meaning depends on where they appear (a malformed identifier
//! vs. a malformed number or duration) are lexed as [`TokenKind::Word`] and classified by
//! the parser.

use crate::ast::{Comment, DurationUnit};
use crate::diag::{Code, Diagnostic};
use crate::span::{Pos, Span};

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
pub fn lex(src: &str) -> LexOutput {
    let mut lexer = Lexer {
        src,
        pos: Pos::START,
        out: LexOutput {
            tokens: Vec::new(),
            comments: Vec::new(),
            diagnostics: Vec::new(),
        },
    };
    lexer.run();
    lexer.out
}

/// Longest identifier (SPEC-01 §2).
const MAX_IDENT_CHARS: usize = 40;
/// Longest string value after unescaping (SPEC-01 §2).
const MAX_STRING_CHARS: usize = 500;

fn is_word_char(c: char) -> bool {
    c == '_' || c.is_alphanumeric()
}

/// Characters that can start a token (or are whitespace), i.e. that end a run of
/// unexpected characters.
fn starts_token(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t'
            | '\n'
            | '\r'
            | '#'
            | '"'
            | '@'
            | '{'
            | '}'
            | '('
            | ')'
            | ':'
            | ','
            | '/'
            | '%'
            | '<'
            | '>'
            | '-'
    ) || is_word_char(c)
}

/// `[a-z][a-z0-9_]*`, at most 40 characters (keywords are excluded by the caller).
fn is_ident(word: &str) -> bool {
    let mut chars = word.chars();
    word.len() <= MAX_IDENT_CHARS
        && chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// `[a-z0-9][a-z0-9_-]{1,29}` (the handle without `@`).
fn is_handle(body: &str) -> bool {
    let lead = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit();
    (2..=30).contains(&body.len())
        && body.chars().next().is_some_and(lead)
        && body.chars().all(|c| lead(c) || c == '_' || c == '-')
}

/// The digits of a valid `INT` (single `_` only between digits), underscores removed.
fn int_digits(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let valid = bytes.first().is_some_and(u8::is_ascii_digit)
        && bytes.last().is_some_and(u8::is_ascii_digit)
        && bytes.iter().all(|b| b.is_ascii_digit() || *b == b'_')
        && !text.contains("__");
    valid.then(|| text.replace('_', ""))
}

fn days_in_month(year: u16, month: u8) -> u8 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Validates a date candidate, returning `(year, month, day)` or why it is invalid.
fn parse_date(text: &str) -> Result<(u16, u8, u8), &'static str> {
    let b = text.as_bytes();
    let shape = b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter()
            .enumerate()
            .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit());
    if !shape {
        return Err("expected YYYY-MM-DD");
    }
    let num = |r: std::ops::Range<usize>| {
        b[r].iter()
            .fold(0u16, |acc, d| acc * 10 + u16::from(d - b'0'))
    };
    let (year, month, day) = (num(0..4), num(5..7), num(8..10));
    if !(2000..=2999).contains(&year) {
        return Err("the year must be between 2000 and 2999");
    }
    let (Ok(month), Ok(day)) = (u8::try_from(month), u8::try_from(day)) else {
        return Err("no such date");
    };
    if !(1..=12).contains(&month) || day == 0 || day > days_in_month(year, month) {
        return Err("no such date");
    }
    Ok((year, month, day))
}

struct Lexer<'a> {
    src: &'a str,
    pos: Pos,
    out: LexOutput,
}

impl Lexer<'_> {
    fn peek(&self) -> Option<char> {
        self.src.get(self.pos.offset..)?.chars().next()
    }

    fn peek_second(&self) -> Option<char> {
        self.src.get(self.pos.offset..)?.chars().nth(1)
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos.offset += c.len_utf8();
        if c == '\n' {
            self.pos.line += 1;
            self.pos.col = 1;
        } else {
            self.pos.col += 1;
        }
        Some(c)
    }

    fn bump_while(&mut self, pred: impl Fn(char) -> bool) {
        while self.peek().is_some_and(&pred) {
            self.bump();
        }
    }

    fn text(&self, start: Pos) -> &str {
        self.src
            .get(start.offset..self.pos.offset)
            .unwrap_or_default()
    }

    fn push(&mut self, kind: TokenKind, start: Pos) {
        self.out.tokens.push(Token {
            kind,
            span: Span::new(start, self.pos),
        });
    }

    /// Reports a lexical error and leaves an [`TokenKind::Error`] token from `start`.
    fn error(&mut self, code: Code, message: String, span: Span, start: Pos) {
        self.out
            .diagnostics
            .push(Diagnostic::new(code, message, span));
        self.push(TokenKind::Error, start);
    }

    fn run(&mut self) {
        while let Some(c) = self.peek() {
            let start = self.pos;
            match c {
                ' ' | '\t' | '\n' | '\r' => {
                    self.bump();
                }
                '#' => self.comment(start),
                '"' => self.string(start),
                '@' => self.handle(start),
                '0'..='9' => self.number(start),
                c if is_word_char(c) => self.word(start),
                _ => self.punct(c, start),
            }
        }
        let end = self.pos;
        self.push(TokenKind::Eof, end);
    }

    fn punct(&mut self, c: char, start: Pos) {
        let second = self.peek_second();
        let (kind, len) = match (c, second) {
            ('{', _) => (TokenKind::LBrace, 1),
            ('}', _) => (TokenKind::RBrace, 1),
            ('(', _) => (TokenKind::LParen, 1),
            (')', _) => (TokenKind::RParen, 1),
            (':', _) => (TokenKind::Colon, 1),
            (',', _) => (TokenKind::Comma, 1),
            ('/', _) => (TokenKind::Slash, 1),
            ('%', _) => (TokenKind::Percent, 1),
            ('<', Some('=')) => (TokenKind::Le, 2),
            ('<', _) => (TokenKind::Lt, 1),
            ('>', Some('=')) => (TokenKind::Ge, 2),
            ('>', _) => (TokenKind::Gt, 1),
            ('=', Some('=')) => (TokenKind::EqEq, 2),
            ('-', Some('>')) => (TokenKind::Arrow, 2),
            ('-', _) => (TokenKind::Minus, 1),
            _ => return self.unexpected(start),
        };
        for _ in 0..len {
            self.bump();
        }
        self.push(kind, start);
    }

    /// A run of characters that cannot start a token: one E101.
    fn unexpected(&mut self, start: Pos) {
        self.bump();
        loop {
            match self.peek() {
                Some('=') if self.peek_second() != Some('=') => {}
                Some(c) if !starts_token(c) && c != '=' => {}
                _ => break,
            }
            self.bump();
        }
        let text = self.text(start);
        let plural = if text.chars().count() > 1 { "s" } else { "" };
        let message = format!("unexpected character{plural} `{}`", text.escape_debug());
        let span = Span::new(start, self.pos);
        self.error(Code::E101, message, span, start);
    }

    fn comment(&mut self, start: Pos) {
        self.bump_while(|c| c != '\n');
        let raw = self.text(start);
        let text = raw.trim_end_matches('\r');
        let stripped = raw.len() - text.len();
        let end = Pos {
            line: self.pos.line,
            col: self.pos.col - stripped as u32,
            offset: self.pos.offset - stripped,
        };
        self.out.comments.push(Comment {
            text: text.to_string(),
            span: Span::new(start, end),
        });
    }

    fn string(&mut self, start: Pos) {
        self.bump();
        let mut value = String::new();
        let mut first_line_end = None;
        let mut bad_escape: Option<(Span, char)> = None;
        loop {
            let Some(c) = self.peek() else {
                let end = first_line_end.unwrap_or(self.pos);
                self.error(
                    Code::E102,
                    "unterminated string: missing closing `\"`".to_string(),
                    Span::new(start, end),
                    start,
                );
                return;
            };
            let at = self.pos;
            self.bump();
            match c {
                '"' => break,
                '\\' => match self.peek() {
                    Some('"') => value.push('"'),
                    Some('\\') => value.push('\\'),
                    Some('n') => value.push('\n'),
                    Some(e) if e != '\n' && e != '\r' => {
                        if bad_escape.is_none() {
                            let mut end = self.pos;
                            end.offset += e.len_utf8();
                            end.col += 1;
                            bad_escape = Some((Span::new(at, end), e));
                        }
                    }
                    // A backslash before a line break or EOF: the next iteration reports it.
                    _ => continue,
                },
                '\n' | '\r' => {
                    first_line_end.get_or_insert(at);
                    value.push(c);
                    continue;
                }
                c => {
                    value.push(c);
                    continue;
                }
            }
            // The escaped character.
            self.bump();
        }
        let span = Span::new(start, self.pos);
        if first_line_end.is_some() {
            self.error(
                Code::E108,
                "string contains a raw line break; write `\\n` instead".to_string(),
                span,
                start,
            );
        } else if let Some((escape_span, e)) = bad_escape {
            self.error(
                Code::E101,
                format!(
                    "unknown escape `\\{}` in string; use `\\\"`, `\\\\` or `\\n`",
                    e.escape_debug()
                ),
                escape_span,
                start,
            );
        } else if value.chars().count() > MAX_STRING_CHARS {
            let n = value.chars().count();
            self.error(
                Code::E108,
                format!("string is {n} characters long; the maximum is {MAX_STRING_CHARS}"),
                span,
                start,
            );
        } else {
            self.push(TokenKind::Str(value), start);
        }
    }

    fn handle(&mut self, start: Pos) {
        self.bump();
        self.bump_while(|c| c == '-' || is_word_char(c));
        let text = self.text(start);
        let body = text.get(1..).unwrap_or_default();
        if is_handle(body) {
            let name = body.to_string();
            self.push(TokenKind::Handle(name), start);
        } else {
            let message = format!(
                "invalid handle `{text}`: a handle is `@` then 2–30 of `a-z`, `0-9`, `_`, `-`, starting with a letter or digit"
            );
            let span = Span::new(start, self.pos);
            self.error(Code::E106, message, span, start);
        }
    }

    /// A word starting with a letter or `_`: keyword, identifier, or [`TokenKind::Word`].
    fn word(&mut self, start: Pos) {
        self.bump_while(is_word_char);
        let text = self.text(start);
        let kind = if let Some(kw) = Keyword::from_word(text) {
            TokenKind::Keyword(kw)
        } else if is_ident(text) {
            TokenKind::Ident(text.to_string())
        } else {
            let numeric = text.starts_with('_')
                && text.bytes().any(|b| b.is_ascii_digit())
                && text.bytes().all(|b| b.is_ascii_digit() || b == b'_');
            TokenKind::Word {
                text: text.to_string(),
                numeric,
            }
        };
        self.push(kind, start);
    }

    /// A word starting with a digit: `INT`, `DECIMAL`, `DURATION`, `DATE`, or a numeric
    /// [`TokenKind::Word`]. Dates and oversized durations are validated here.
    fn number(&mut self, start: Pos) {
        self.bump_while(is_word_char);
        let dash_word =
            |l: &Self| l.peek() == Some('-') && l.peek_second().is_some_and(is_word_char);
        if self.text(start).bytes().all(|b| b.is_ascii_digit()) && dash_word(self) {
            for _ in 0..2 {
                if dash_word(self) {
                    self.bump();
                    self.bump_while(is_word_char);
                }
            }
            return self.date(start);
        }
        while self.peek() == Some('.') {
            self.bump();
            self.bump_while(is_word_char);
        }
        let text = self.text(start);
        if let Some(digits) = int_digits(text) {
            return self.push(TokenKind::Int(digits), start);
        }
        if let Some((int, frac)) = text.split_once('.') {
            if let Some(int) = int_digits(int) {
                if !frac.is_empty() && frac.bytes().all(|b| b.is_ascii_digit()) {
                    let frac = frac.to_string();
                    return self.push(TokenKind::Decimal { int, frac }, start);
                }
            }
        }
        let unit = text.chars().last().and_then(DurationUnit::from_char);
        let count = text
            .get(..text.len().saturating_sub(1))
            .and_then(int_digits);
        if let (Some(unit), Some(count)) = (unit, count) {
            match count
                .parse::<u64>()
                .ok()
                .filter(|v| v.checked_mul(unit.secs()).is_some())
            {
                Some(value) => self.push(TokenKind::Duration { value, unit }, start),
                None => {
                    let message = format!("duration `{text}` is too large");
                    let span = Span::new(start, self.pos);
                    self.error(Code::E104, message, span, start);
                }
            }
            return;
        }
        let text = text.to_string();
        self.push(
            TokenKind::Word {
                text,
                numeric: true,
            },
            start,
        );
    }

    fn date(&mut self, start: Pos) {
        let text = self.text(start);
        match parse_date(text) {
            Ok((year, month, day)) => self.push(TokenKind::Date { year, month, day }, start),
            Err(why) => {
                let message = format!("invalid date `{text}`: {why}");
                let span = Span::new(start, self.pos);
                self.error(Code::E105, message, span, start);
            }
        }
    }
}
