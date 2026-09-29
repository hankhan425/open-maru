//! Recursive-descent parser for maru-lang v0 (SPEC-01 §3) with error recovery.
//!
//! Recovery: when an item inside a block has an error, the item is left out of the tree
//! and the parser skips to the next item keyword of that block or its closing `}` (at the
//! same brace depth), so one mistake yields one diagnostic. A keyword that can only start
//! an item of an *enclosing* block (e.g. `rule` inside a mandate) is treated as a missing
//! `}` when too few `}` remain in the file to close every open block: the current block
//! closes with one E201 ("expected `}`") and the enclosing block parses the item.
//! Otherwise it is a misplaced item (one E201) and is skipped. Tokens the lexer already
//! reported are absorbed silently.

use crate::ast::*;
use crate::diag::{Code, Diagnostic};
use crate::lexer::{Keyword, LexOutput, Token, TokenKind, lex};
use crate::span::{Pos, Span};

/// Largest accepted source, in bytes (E109).
pub const MAX_SOURCE_BYTES: usize = 256 * 1024;

/// The parser's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseOutput {
    /// The syntax tree, when an org header was found. Items with errors are left out.
    pub file: Option<File>,
    /// Lexical and syntax errors, ordered by position.
    pub diagnostics: Vec<Diagnostic>,
}

/// Parses a `.maru` source into a syntax tree.
///
/// Sources over [`MAX_SOURCE_BYTES`] are rejected with a single E109 and not lexed.
pub fn parse(src: &str) -> ParseOutput {
    if src.len() > MAX_SOURCE_BYTES {
        let message = format!(
            "source is {} bytes; the maximum is {MAX_SOURCE_BYTES} bytes (256 KiB)",
            src.len()
        );
        return ParseOutput {
            file: None,
            diagnostics: vec![Diagnostic::new(
                Code::E109,
                message,
                Span::point(Pos::START),
            )],
        };
    }
    let mut parser = Parser::new(src, lex(src));
    let file = parser.file();
    let mut diagnostics = parser.diags;
    diagnostics.sort_by_key(|d| d.span.start.offset);
    ParseOutput { file, diagnostics }
}

/// A diagnostic has been recorded (by the lexer or the parser); the caller recovers.
struct Recover;

type PResult<T> = Result<T, Recover>;

/// The block being parsed, which decides its item keywords and recovery points.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ctx {
    Org,
    Circle,
    Agent,
    Goal,
    Mandate,
}

impl Ctx {
    fn name(self) -> &'static str {
        match self {
            Ctx::Org => "org",
            Ctx::Circle => "circle",
            Ctx::Agent => "agent",
            Ctx::Goal => "goal",
            Ctx::Mandate => "mandate",
        }
    }

    fn items(self) -> &'static [Keyword] {
        use Keyword as K;
        match self {
            Ctx::Org => &[
                K::Purpose,
                K::Members,
                K::Amend,
                K::Circle,
                K::Agent,
                K::Goal,
            ],
            Ctx::Circle => &[K::Seats, K::Term, K::Holders],
            Ctx::Agent => &[K::Operator, K::Runtime],
            Ctx::Goal => &[
                K::Steward,
                K::Purpose,
                K::Fund,
                K::OnUnderfunded,
                K::OnClose,
                K::Success,
                K::Mandate,
                K::Rule,
            ],
            Ctx::Mandate => &[K::Spend, K::PerRequest, K::Can, K::Expires],
        }
    }

    fn parent(self) -> Option<Ctx> {
        match self {
            Ctx::Org => None,
            Ctx::Circle | Ctx::Agent | Ctx::Goal => Some(Ctx::Org),
            Ctx::Mandate => Some(Ctx::Goal),
        }
    }

    fn starts_item(self, kw: Keyword) -> bool {
        self.items().contains(&kw)
    }

    /// Whether `kw` starts an item of an enclosing block but not of this one.
    fn closed_by(self, kw: Keyword) -> bool {
        if self.starts_item(kw) {
            return false;
        }
        let mut ctx = self.parent();
        while let Some(c) = ctx {
            if c.starts_item(kw) {
                return true;
            }
            ctx = c.parent();
        }
        false
    }

    /// "a goal item (`steward`, …, `rule`) or `}`".
    fn expected_item(self) -> String {
        let list: Vec<String> = self
            .items()
            .iter()
            .map(|k| format!("`{}`", k.as_str()))
            .collect();
        let article = match self {
            Ctx::Org | Ctx::Agent => "an",
            _ => "a",
        };
        format!(
            "{article} {} item ({}) or `}}`",
            self.name(),
            list.join(", ")
        )
    }
}

/// What the next token means to a block's item loop.
enum Next {
    Close,
    Eof,
    Item(Keyword),
    ClosesBlock(Keyword),
    Reported,
    Other,
}

type ItemFn<'a, K> = fn(&mut Parser<'a>, Keyword, Span) -> PResult<K>;

struct Parser<'a> {
    src: &'a str,
    toks: Vec<Token>,
    pos: usize,
    comments: Vec<Comment>,
    next_comment: usize,
    diags: Vec<Diagnostic>,
    /// An E202 (or an E102 string running to EOF) was reported; don't report EOF again.
    eof_reported: bool,
    /// Token index at which an implicit block close was reported, so enclosing blocks
    /// closing at the same token stay silent.
    closed_at: Option<usize>,
    /// Blocks opened and not yet closed.
    open_blocks: usize,
    /// `closers_after[i]`: count of `}` minus count of `{` in `toks[i..]`.
    closers_after: Vec<isize>,
}

impl<'a> Parser<'a> {
    fn new(src: &'a str, lexed: LexOutput) -> Parser<'a> {
        let eof_reported = lexed.diagnostics.iter().any(|d| d.code == Code::E102);
        let mut toks = lexed.tokens;
        if toks.is_empty() {
            toks.push(Token {
                kind: TokenKind::Eof,
                span: Span::point(Pos::START),
            });
        }
        let mut closers_after = vec![0isize; toks.len() + 1];
        for (i, tok) in toks.iter().enumerate().rev() {
            let delta = match tok.kind {
                TokenKind::RBrace => 1,
                TokenKind::LBrace => -1,
                _ => 0,
            };
            closers_after[i] = closers_after[i + 1] + delta;
        }
        Parser {
            src,
            toks,
            pos: 0,
            comments: lexed.comments,
            next_comment: 0,
            diags: lexed.diagnostics,
            eof_reported,
            closed_at: None,
            open_blocks: 0,
            closers_after,
        }
    }

    // ---- tokens ----

    fn peek(&self) -> &Token {
        let i = self.pos.min(self.toks.len() - 1);
        &self.toks[i]
    }

    fn kind(&self) -> &TokenKind {
        &self.peek().kind
    }

    fn span(&self) -> Span {
        self.peek().span
    }

    /// Consumes the current token (never moves past EOF) and returns its span.
    fn bump(&mut self) -> Span {
        let span = self.span();
        if self.pos + 1 < self.toks.len() {
            self.pos += 1;
        }
        span
    }

    /// The span of the last consumed token.
    fn prev_span(&self) -> Span {
        self.toks[self.pos.saturating_sub(1).min(self.toks.len() - 1)].span
    }

    fn at_kw(&self, kw: Keyword) -> bool {
        *self.kind() == TokenKind::Keyword(kw)
    }

    fn eat_kw(&mut self, kw: Keyword) -> Option<Span> {
        self.at_kw(kw).then(|| self.bump())
    }

    fn eat(&mut self, kind: &TokenKind) -> Option<Span> {
        (self.kind() == kind).then(|| self.bump())
    }

    // ---- diagnostics ----

    fn report(&mut self, code: Code, message: String, span: Span) -> Recover {
        self.diags.push(Diagnostic::new(code, message, span));
        Recover
    }

    fn source(&self, span: Span) -> &'a str {
        self.src.get(span.range()).unwrap_or_default()
    }

    /// How a token is named in "found …".
    fn describe(&self, tok: &Token) -> String {
        match &tok.kind {
            TokenKind::Eof => "end of file".to_string(),
            TokenKind::Str(_) => "a string".to_string(),
            TokenKind::Ident(name) => format!("identifier `{name}`"),
            _ => {
                let text = self.source(tok.span);
                let short: String = text.chars().take(32).collect();
                let ellipsis = if short.len() < text.len() { "…" } else { "" };
                format!("`{short}{ellipsis}`")
            }
        }
    }

    /// Reports that `expected` was not found at the current token (E201, or E202 at EOF),
    /// without consuming it. A token the lexer already reported is consumed silently.
    fn expected(&mut self, expected: &str) -> Recover {
        let tok = self.peek().clone();
        match tok.kind {
            TokenKind::Error => {
                self.bump();
                Recover
            }
            TokenKind::Eof => {
                if !self.eof_reported {
                    self.eof_reported = true;
                    let message = format!("unexpected end of file; expected {expected}");
                    return self.report(Code::E202, message, Span::point(tok.span.start));
                }
                Recover
            }
            _ => {
                let message = format!("expected {expected}, found {}", self.describe(&tok));
                self.report(Code::E201, message, tok.span)
            }
        }
    }

    fn expect(&mut self, kind: &TokenKind, expected: &str) -> PResult<Span> {
        match self.eat(kind) {
            Some(span) => Ok(span),
            None => Err(self.expected(expected)),
        }
    }

    fn colon(&mut self) -> PResult<Span> {
        self.expect(&TokenKind::Colon, "`:`")
    }

    fn expect_kw(&mut self, kw: Keyword) -> PResult<Span> {
        match self.eat_kw(kw) {
            Some(span) => Ok(span),
            None => Err(self.expected(&format!("`{}`", kw.as_str()))),
        }
    }

    /// One of `kws`, e.g. `pause` or `continue`.
    fn one_of(&mut self, kws: &[Keyword]) -> PResult<(Keyword, Span)> {
        if let TokenKind::Keyword(kw) = *self.kind() {
            if kws.contains(&kw) {
                return Ok((kw, self.bump()));
            }
        }
        let names: Vec<String> = kws.iter().map(|k| format!("`{}`", k.as_str())).collect();
        let expected = match names.split_last() {
            Some((last, [])) => last.clone(),
            Some((last, rest)) => format!("{} or {last}", rest.join(", ")),
            None => "a keyword".to_string(),
        };
        Err(self.expected(&expected))
    }

    /// Reports `code` at the current (malformed) token and consumes it.
    fn malformed(&mut self, code: Code, message: String) -> Recover {
        let span = self.bump();
        self.report(code, message, span)
    }

    // ---- literals ----

    fn ident(&mut self, what: &str) -> PResult<Ident> {
        let span = self.span();
        match self.kind() {
            TokenKind::Ident(name) => {
                let name = name.clone();
                self.bump();
                Ok(Ident { name, span })
            }
            TokenKind::Keyword(kw) => {
                let message = format!(
                    "`{}` is a reserved keyword and cannot be used as {what}",
                    kw.as_str()
                );
                Err(self.malformed(Code::E107, message))
            }
            TokenKind::Word { .. }
            | TokenKind::Int(_)
            | TokenKind::Decimal { .. }
            | TokenKind::Duration { .. } => {
                let message = format!(
                    "invalid identifier `{}`: use 1–40 of `a-z`, `0-9`, `_`, starting with a letter",
                    self.source(span)
                );
                Err(self.malformed(Code::E107, message))
            }
            _ => Err(self.expected(what)),
        }
    }

    fn handle(&mut self, what: &str) -> PResult<Handle> {
        let span = self.span();
        if let TokenKind::Handle(name) = self.kind() {
            let name = name.clone();
            self.bump();
            return Ok(Handle { name, span });
        }
        Err(self.expected(what))
    }

    fn string(&mut self, what: &str) -> PResult<Str> {
        let span = self.span();
        if let TokenKind::Str(value) = self.kind() {
            let value = value.clone();
            self.bump();
            return Ok(Str { value, span });
        }
        Err(self.expected(what))
    }

    fn malformed_number(&mut self) -> Recover {
        let message = format!(
            "malformed number `{}`: `_` may only appear singly between digits",
            self.source(self.span())
        );
        self.malformed(Code::E103, message)
    }

    fn int(&mut self, what: &str) -> PResult<Int> {
        let span = self.span();
        match self.kind() {
            TokenKind::Int(digits) => match digits.parse::<u64>() {
                Ok(value) if value <= MAX_INT => {
                    self.bump();
                    Ok(Int { value, span })
                }
                _ => {
                    let message = format!(
                        "number `{}` is too large; the maximum is 2_147_483_647",
                        self.source(span)
                    );
                    Err(self.malformed(Code::E103, message))
                }
            },
            TokenKind::Word { numeric: true, .. } => Err(self.malformed_number()),
            _ => Err(self.expected(what)),
        }
    }

    fn duration(&mut self, what: &str) -> PResult<Duration> {
        let span = self.span();
        match *self.kind() {
            TokenKind::Duration { value, unit } => {
                self.bump();
                Ok(Duration { value, unit, span })
            }
            TokenKind::Int(_)
            | TokenKind::Decimal { .. }
            | TokenKind::Word { numeric: true, .. } => {
                let message = format!(
                    "malformed duration `{}`: expected a whole number followed by `m`, `h`, `d`, `w` or `y`",
                    self.source(span)
                );
                Err(self.malformed(Code::E104, message))
            }
            _ => Err(self.expected(what)),
        }
    }

    fn date(&mut self, what: &str) -> PResult<Date> {
        let span = self.span();
        match *self.kind() {
            TokenKind::Date { year, month, day } => {
                self.bump();
                Ok(Date {
                    year,
                    month,
                    day,
                    span,
                })
            }
            TokenKind::Int(_)
            | TokenKind::Decimal { .. }
            | TokenKind::Duration { .. }
            | TokenKind::Word { numeric: true, .. } => {
                let message = format!("invalid date `{}`: expected YYYY-MM-DD", self.source(span));
                Err(self.malformed(Code::E105, message))
            }
            _ => Err(self.expected(what)),
        }
    }

    /// `usd (INT | DECIMAL)`, exact in micro-USD.
    fn money(&mut self) -> PResult<Money> {
        let usd = self.expect_kw(Keyword::Usd)?;
        let span = self.span();
        let (int, frac) = match self.kind() {
            TokenKind::Int(int) => (int.clone(), String::new()),
            TokenKind::Decimal { int, frac } => (int.clone(), frac.clone()),
            TokenKind::Word { numeric: true, .. } => return Err(self.malformed_number()),
            _ => return Err(self.expected("an amount")),
        };
        if frac.len() > 6 {
            let message = format!(
                "`{}` has {} decimal places; money allows at most 6",
                self.source(span),
                frac.len()
            );
            return Err(self.malformed(Code::E311, message));
        }
        let micros = int
            .parse::<u64>()
            .ok()
            .and_then(|whole| whole.checked_mul(1_000_000))
            .and_then(|whole| {
                let frac = if frac.is_empty() {
                    0
                } else {
                    format!("{frac:0<6}").parse::<u64>().ok()?
                };
                whole.checked_add(frac)
            })
            .filter(|m| *m <= MAX_MONEY_MICROS);
        let Some(micros) = micros else {
            let message = format!(
                "`{}` exceeds the maximum amount of 9007199254.740991 (2^53 − 1 micro-USD)",
                self.source(span)
            );
            return Err(self.malformed(Code::E310, message));
        };
        self.bump();
        Ok(Money {
            micros,
            span: usd.to(span),
        })
    }

    /// `["-"] (INT | DECIMAL)` for metric targets.
    fn signed(&mut self) -> PResult<Signed> {
        let start = self.span();
        let negative = self.eat(&TokenKind::Minus).is_some();
        let span = self.span();
        let (int, frac) = match self.kind() {
            TokenKind::Int(int) => (int.clone(), None),
            TokenKind::Decimal { int, frac } => (int.clone(), Some(frac.clone())),
            TokenKind::Word { numeric: true, .. } => return Err(self.malformed_number()),
            _ => return Err(self.expected("a number")),
        };
        self.bump();
        Ok(Signed {
            negative,
            int,
            frac,
            span: start.to(span),
        })
    }

    fn threshold(&mut self) -> PResult<Threshold> {
        let first = self.int("a threshold (`a/b` or `p%`)")?;
        if self.eat(&TokenKind::Slash).is_some() {
            let den = self.int("a denominator")?;
            let span = first.span.to(den.span);
            return Ok(Threshold {
                kind: ThresholdKind::Fraction { num: first, den },
                span,
            });
        }
        let percent = self.expect(&TokenKind::Percent, "`/` or `%`")?;
        Ok(Threshold {
            span: first.span.to(percent),
            kind: ThresholdKind::Percent { value: first },
        })
    }

    fn category(&mut self) -> Option<Category> {
        let category = match self.kind() {
            TokenKind::Keyword(Keyword::Llm) => Category::Llm,
            TokenKind::Keyword(Keyword::Compute) => Category::Compute,
            TokenKind::Keyword(Keyword::Expense) => Category::Expense,
            _ => return None,
        };
        self.bump();
        Some(category)
    }

    fn period(&mut self) -> PResult<Period> {
        let (kw, _) = self.one_of(&[Keyword::Day, Keyword::Week, Keyword::Month])?;
        Ok(match kw {
            Keyword::Day => Period::Day,
            Keyword::Week => Period::Week,
            _ => Period::Month,
        })
    }

    fn cmp(&mut self) -> PResult<Cmp> {
        let cmp = match self.kind() {
            TokenKind::Ge => Cmp::Ge,
            TokenKind::Gt => Cmp::Gt,
            TokenKind::Le => Cmp::Le,
            TokenKind::Lt => Cmp::Lt,
            TokenKind::EqEq => Cmp::Eq,
            _ => return Err(self.expected("a comparator (`>=`, `>`, `<=`, `<` or `==`)")),
        };
        self.bump();
        Ok(cmp)
    }

    // ---- shared phrases ----

    fn procedure(&mut self) -> PResult<Procedure> {
        let (kw, start) = self.one_of(&[Keyword::Approve, Keyword::Vote])?;
        self.expect(&TokenKind::LParen, "`(`")?;
        let group = match self.eat_kw(Keyword::Members) {
            Some(span) => Group::Members { span },
            None => Group::Circle(self.ident("a circle id or `members`")?),
        };
        self.expect(&TokenKind::Comma, "`,`")?;
        let kind = if kw == Keyword::Approve {
            let count = self.int("an approval count")?;
            ProcedureKind::Approve { group, count }
        } else {
            let threshold = self.threshold()?;
            ProcedureKind::Vote { group, threshold }
        };
        let end = self.expect(&TokenKind::RParen, "`)`")?;
        Ok(Procedure {
            kind,
            span: start.to(end),
        })
    }

    fn timeout(&mut self) -> PResult<Option<Timeout>> {
        let Some(start) = self.eat_kw(Keyword::Within) else {
            return Ok(None);
        };
        let within = self.duration("a duration such as `48h` or `7d`")?;
        self.expect_kw(Keyword::Else)?;
        let (kw, end) = self.one_of(&[Keyword::Deny, Keyword::Allow])?;
        let outcome = if kw == Keyword::Deny {
            Outcome::Deny
        } else {
            Outcome::Allow
        };
        Ok(Some(Timeout {
            within,
            outcome,
            span: start.to(end),
        }))
    }

    // ---- comments ----

    /// All unattached comments that start before `offset`.
    fn comments_before(&mut self, offset: usize) -> Vec<Comment> {
        let start = self.next_comment;
        while self
            .comments
            .get(self.next_comment)
            .is_some_and(|c| c.span.start.offset < offset)
        {
            self.next_comment += 1;
        }
        self.comments[start..self.next_comment].to_vec()
    }

    /// The next comment, if it follows `after` on the same line.
    fn trailing_comment(&mut self, after: Span) -> Option<Comment> {
        let next_token = self.span().start.offset;
        let c = self.comments.get(self.next_comment)?;
        let same_line = c.span.start.line == after.end.line
            && c.span.start.offset >= after.end.offset
            && c.span.start.offset < next_token;
        if same_line {
            self.next_comment += 1;
            Some(c.clone())
        } else {
            None
        }
    }

    // ---- blocks and items ----

    /// Whether fewer `}` remain than blocks are open, i.e. some `}` is missing.
    fn missing_closer(&self) -> bool {
        let remaining = self.closers_after.get(self.pos).copied().unwrap_or(0);
        remaining < self.open_blocks as isize
    }

    /// Whether `kw` should close the current `ctx` block (see the module docs).
    fn closes(&self, ctx: Ctx, kw: Keyword) -> bool {
        ctx.closed_by(kw) && self.missing_closer()
    }

    fn next_in(&self, ctx: Ctx) -> Next {
        match self.kind() {
            TokenKind::RBrace => Next::Close,
            TokenKind::Eof => Next::Eof,
            TokenKind::Error => Next::Reported,
            TokenKind::Keyword(kw) if ctx.starts_item(*kw) => Next::Item(*kw),
            TokenKind::Keyword(kw) if self.closes(ctx, *kw) => Next::ClosesBlock(*kw),
            _ => Next::Other,
        }
    }

    /// Skips to the next item keyword of `ctx` (or of an enclosing block) or `}` at the
    /// current brace depth, or EOF.
    fn sync(&mut self, ctx: Ctx) {
        let mut depth = 0usize;
        loop {
            match self.kind() {
                TokenKind::Eof => return,
                TokenKind::LBrace => depth += 1,
                TokenKind::RBrace if depth == 0 => return,
                TokenKind::RBrace => depth -= 1,
                TokenKind::Keyword(kw)
                    if depth == 0 && (ctx.starts_item(*kw) || self.closes(ctx, *kw)) =>
                {
                    return;
                }
                _ => {}
            }
            self.bump();
        }
    }

    /// `{ item* }` with recovery. Returns the (possibly partial) block unless `{` is
    /// missing.
    fn block<K>(&mut self, ctx: Ctx, item: ItemFn<'a, K>) -> PResult<Block<K>> {
        let open = self.expect(&TokenKind::LBrace, "`{`")?;
        self.open_blocks += 1;
        let block = self.block_items(ctx, item, open);
        self.open_blocks -= 1;
        Ok(block)
    }

    fn block_items<K>(&mut self, ctx: Ctx, item: ItemFn<'a, K>, open: Span) -> Block<K> {
        let open_comment = self.trailing_comment(open);
        let mut items = Vec::new();
        loop {
            let at = self.span();
            match self.next_in(ctx) {
                Next::Close => {
                    let end_comments = self.comments_before(at.start.offset);
                    self.bump();
                    return Block {
                        items,
                        open_comment,
                        end_comments,
                        span: open.to(at),
                    };
                }
                Next::Eof => {
                    if !self.eof_reported {
                        self.eof_reported = true;
                        let message = format!(
                            "unexpected end of file; expected `}}` to close the {} block",
                            ctx.name()
                        );
                        let note = format!(
                            "the {} block opens at line {}, column {}",
                            ctx.name(),
                            open.start.line,
                            open.start.col
                        );
                        self.diags.push(
                            Diagnostic::new(Code::E202, message, Span::point(at.start))
                                .with_note(note),
                        );
                    }
                    let end_comments = self.comments_before(at.start.offset);
                    return Block {
                        items,
                        open_comment,
                        end_comments,
                        span: open.to(self.prev_span()),
                    };
                }
                Next::ClosesBlock(kw) => {
                    if self.closed_at != Some(self.pos) {
                        self.closed_at = Some(self.pos);
                        let message = format!(
                            "expected `}}` to close the {} block, found `{}`",
                            ctx.name(),
                            kw.as_str()
                        );
                        let note = format!(
                            "`{}` cannot appear inside a {} block",
                            kw.as_str(),
                            ctx.name()
                        );
                        self.diags
                            .push(Diagnostic::new(Code::E201, message, at).with_note(note));
                    }
                    return Block {
                        items,
                        open_comment,
                        end_comments: Vec::new(),
                        span: open.to(self.prev_span()),
                    };
                }
                Next::Item(kw) => {
                    let mut leading = self.comments_before(at.start.offset);
                    self.bump();
                    match item(self, kw, at) {
                        Ok(node) => {
                            let last = self.prev_span();
                            leading.extend(self.comments_before(last.end.offset));
                            let trailing = self.trailing_comment(last);
                            items.push(Item {
                                node,
                                leading,
                                trailing,
                                span: at.to(last),
                            });
                        }
                        Err(Recover) => self.sync(ctx),
                    }
                }
                Next::Reported => {
                    self.bump();
                    self.sync(ctx);
                }
                Next::Other => {
                    let _ = self.expected(&ctx.expected_item());
                    self.bump();
                    self.sync(ctx);
                }
            }
        }
    }

    fn file(&mut self) -> Option<File> {
        let mut reported = false;
        loop {
            match self.kind() {
                TokenKind::Keyword(Keyword::Org) => break,
                TokenKind::Eof => {
                    if !reported {
                        let _ = self.expected("`org`");
                    }
                    return None;
                }
                TokenKind::Error => {
                    self.bump();
                }
                _ => {
                    if !reported {
                        reported = true;
                        let _ = self.expected("`org`");
                    }
                    self.bump();
                }
            }
        }
        let start = self.span();
        let mut leading = self.comments_before(start.start.offset);
        self.bump();
        let name = self.string("the org name").ok()?;
        let body = self.block(Ctx::Org, Parser::org_item).ok()?;
        let last = self.prev_span();
        leading.extend(self.comments_before(last.end.offset));
        let trailing = self.trailing_comment(last);
        let org = Item {
            node: Org { name, body },
            leading,
            trailing,
            span: start.to(last),
        };
        loop {
            match self.kind() {
                TokenKind::Eof => break,
                TokenKind::Error => {
                    self.bump();
                }
                _ => {
                    let message =
                        "unexpected content after the org block; a file holds exactly one org"
                            .to_string();
                    let span = self.span();
                    self.report(Code::E203, message, span);
                    break;
                }
            }
        }
        let trailing_comments = self.comments_before(usize::MAX);
        Some(File {
            org,
            trailing_comments,
        })
    }

    fn org_item(&mut self, kw: Keyword, _at: Span) -> PResult<OrgItem> {
        Ok(match kw {
            Keyword::Purpose => OrgItem::Purpose(self.string("a purpose string")?),
            Keyword::Members => {
                self.colon()?;
                OrgItem::Members(self.membership()?)
            }
            Keyword::Amend => {
                self.colon()?;
                let procedure = self.procedure()?;
                let timeout = self.timeout()?;
                OrgItem::Amend(Amend { procedure, timeout })
            }
            Keyword::Circle => {
                let id = self.ident("a circle id")?;
                let body = self.block(Ctx::Circle, Parser::circle_item)?;
                OrgItem::Circle(Circle { id, body })
            }
            Keyword::Agent => {
                let id = self.ident("an agent id")?;
                let body = self.block(Ctx::Agent, Parser::agent_item)?;
                OrgItem::Agent(Agent { id, body })
            }
            _ => {
                let id = self.ident("a goal id")?;
                let title = self.string("a goal title string")?;
                let body = self.block(Ctx::Goal, Parser::goal_item)?;
                OrgItem::Goal(Goal { id, title, body })
            }
        })
    }

    fn membership(&mut self) -> PResult<Membership> {
        let (kw, start) = self.one_of(&[Keyword::Open, Keyword::Invite])?;
        self.expect(&TokenKind::LParen, "`(`")?;
        let kind = if kw == Keyword::Open {
            MembershipKind::Open
        } else {
            self.expect_kw(Keyword::Sponsors)?;
            self.colon()?;
            MembershipKind::Invite {
                sponsors: self.int("a sponsor count")?,
            }
        };
        let end = self.expect(&TokenKind::RParen, "`)`")?;
        Ok(Membership {
            kind,
            span: start.to(end),
        })
    }

    fn circle_item(&mut self, kw: Keyword, _at: Span) -> PResult<CircleItem> {
        self.colon()?;
        Ok(match kw {
            Keyword::Seats => CircleItem::Seats(self.int("a seat count")?),
            Keyword::Term => CircleItem::Term(self.duration("a term such as `1y`")?),
            _ => {
                let mut holders = vec![self.handle("a holder `@handle`")?];
                while self.eat(&TokenKind::Comma).is_some() {
                    holders.push(self.handle("a holder `@handle`")?);
                }
                CircleItem::Holders(holders)
            }
        })
    }

    fn agent_item(&mut self, kw: Keyword, _at: Span) -> PResult<AgentItem> {
        self.colon()?;
        Ok(match kw {
            Keyword::Operator => AgentItem::Operator(self.handle("an operator `@handle`")?),
            _ => match self.one_of(&[Keyword::Byo, Keyword::Hosted])?.0 {
                Keyword::Byo => AgentItem::Runtime(Runtime::Byo),
                _ => AgentItem::Runtime(Runtime::Hosted),
            },
        })
    }

    fn goal_item(&mut self, kw: Keyword, _at: Span) -> PResult<GoalItem> {
        Ok(match kw {
            Keyword::Steward => {
                self.colon()?;
                GoalItem::Steward(self.ident("a circle id")?)
            }
            Keyword::Purpose => GoalItem::Purpose(self.string("a purpose string")?),
            Keyword::Fund => {
                self.colon()?;
                GoalItem::Fund(self.fund()?)
            }
            Keyword::OnUnderfunded => {
                self.colon()?;
                match self.one_of(&[Keyword::Pause, Keyword::Continue])?.0 {
                    Keyword::Pause => GoalItem::OnUnderfunded(Underfunded::Pause),
                    _ => GoalItem::OnUnderfunded(Underfunded::Continue),
                }
            }
            Keyword::OnClose => {
                self.colon()?;
                match self.one_of(&[Keyword::Return, Keyword::Transfer])?.0 {
                    Keyword::Return => {
                        self.expect_kw(Keyword::Treasury)?;
                        GoalItem::OnClose(OnClose::ReturnTreasury)
                    }
                    _ => GoalItem::OnClose(OnClose::Transfer(self.ident("a goal id")?)),
                }
            }
            Keyword::Success => {
                self.colon()?;
                GoalItem::Success(self.success()?)
            }
            Keyword::Mandate => {
                let principal = match self.kind() {
                    TokenKind::Handle(_) => Principal::Person(self.handle("a `@handle`")?),
                    _ => Principal::Agent(self.ident("an agent id or `@handle`")?),
                };
                let body = self.block(Ctx::Mandate, Parser::mandate_item)?;
                GoalItem::Mandate(Mandate { principal, body })
            }
            _ => GoalItem::Rule(self.rule()?),
        })
    }

    fn fund(&mut self) -> PResult<Fund> {
        let amount = self.money()?;
        let schedule = if self.eat(&TokenKind::Slash).is_some() {
            FundSchedule::Every(self.period()?)
        } else if self.eat_kw(Keyword::Once).is_some() {
            FundSchedule::Once
        } else {
            return Err(self.expected("`/ <period>` or `once`"));
        };
        self.expect_kw(Keyword::From)?;
        let end = self.expect_kw(Keyword::Treasury)?;
        let span = amount.span.to(end);
        Ok(Fund {
            amount,
            schedule,
            span,
        })
    }

    fn success(&mut self) -> PResult<Success> {
        let start = self.expect_kw(Keyword::Metric)?;
        self.expect(&TokenKind::LParen, "`(`")?;
        let metric = self.ident("a metric name")?;
        self.expect(&TokenKind::RParen, "`)`")?;
        let cmp = self.cmp()?;
        let value = self.signed()?;
        let by = match self.eat_kw(Keyword::By) {
            Some(_) => Some(self.date("a date (YYYY-MM-DD)")?),
            None => None,
        };
        Ok(Success {
            metric,
            cmp,
            value,
            by,
            span: start.to(self.prev_span()),
        })
    }

    fn rule(&mut self) -> PResult<Rule> {
        let (kw, start) = self.one_of(&[Keyword::Spend, Keyword::Close])?;
        let kind = if kw == Keyword::Close {
            SubjectKind::Close
        } else {
            let category = self.category();
            let over = match self.eat(&TokenKind::Gt) {
                Some(_) => Some(self.money()?),
                None => None,
            };
            SubjectKind::Spend { category, over }
        };
        let subject = Subject {
            kind,
            span: start.to(self.prev_span()),
        };
        self.expect_kw(Keyword::Requires)?;
        let procedure = self.procedure()?;
        let timeout = self.timeout()?;
        Ok(Rule {
            subject,
            procedure,
            timeout,
        })
    }

    fn mandate_item(&mut self, kw: Keyword, _at: Span) -> PResult<MandateItem> {
        Ok(match kw {
            Keyword::Spend => {
                let Some(category) = self.category() else {
                    return Err(self.expected("a category (`llm`, `compute` or `expense`)"));
                };
                self.expect(&TokenKind::Le, "`<=`")?;
                let limit = self.money()?;
                self.expect(&TokenKind::Slash, "`/`")?;
                let period = self.period()?;
                MandateItem::Spend(SpendLimit {
                    category,
                    limit,
                    period,
                })
            }
            Keyword::PerRequest => {
                self.expect(&TokenKind::Le, "`<=`")?;
                MandateItem::PerRequest(self.money()?)
            }
            Keyword::Can => {
                self.colon()?;
                let mut caps = vec![self.capability()?];
                while self.eat(&TokenKind::Comma).is_some() {
                    caps.push(self.capability()?);
                }
                MandateItem::Can(caps)
            }
            _ => {
                self.colon()?;
                MandateItem::Expires(self.date("a date (YYYY-MM-DD)")?)
            }
        })
    }

    fn capability(&mut self) -> PResult<Capability> {
        let (kw, span) = self.one_of(&[
            Keyword::ClaimTasks,
            Keyword::CreateTasks,
            Keyword::PostEvidence,
            Keyword::ReportMetric,
        ])?;
        let kind = match kw {
            Keyword::ClaimTasks => CapabilityKind::ClaimTasks,
            Keyword::CreateTasks => CapabilityKind::CreateTasks,
            Keyword::PostEvidence => CapabilityKind::PostEvidence,
            _ => {
                self.expect(&TokenKind::LParen, "`(`")?;
                let metric = self.ident("a metric name")?;
                let end = self.expect(&TokenKind::RParen, "`)`")?;
                return Ok(Capability {
                    kind: CapabilityKind::ReportMetric(metric),
                    span: span.to(end),
                });
            }
        };
        Ok(Capability { kind, span })
    }
}
