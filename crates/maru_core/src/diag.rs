//! Diagnostics in the SPEC-01 §5 shape, shared by every target.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::span::Span;

/// How serious a diagnostic is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// The source is rejected.
    Error,
    /// The source is accepted, but probably not as intended.
    Warning,
}

macro_rules! codes {
    ($($code:ident: $doc:literal),* $(,)?) => {
        /// A stable diagnostic code (SPEC-01 §5). `E…` codes are errors, `W…` warnings.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        pub enum Code {
            $(#[doc = $doc] $code,)*
        }

        impl Code {
            /// Every code, in table order.
            pub const ALL: &'static [Code] = &[$(Code::$code,)*];

            /// The code as written in the spec, e.g. `"E302"`.
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Code::$code => stringify!($code),)*
                }
            }
        }
    };
}

codes! {
    E101: "Unexpected character.",
    E102: "Unterminated string.",
    E103: "Malformed number (underscores).",
    E104: "Malformed duration.",
    E105: "Invalid date.",
    E106: "Invalid handle.",
    E107: "Invalid or reserved identifier.",
    E108: "String contains raw newline or exceeds 500 chars.",
    E109: "Source exceeds 256 KiB.",
    E201: "Expected X, found Y.",
    E202: "Unexpected end of file.",
    E203: "Content after the org block.",
    E301: "Duplicate circle/agent/goal id.",
    E302: "Unknown circle.",
    E303: "Unknown agent.",
    E304: "Missing required field.",
    E305: "Field given twice in one block.",
    E306: "More holders than seats.",
    E307: "approve count < 1 or > seats.",
    E308: "Threshold out of range.",
    E309: "Money must be > 0.",
    E310: "Money exceeds maximum.",
    E311: "Money has more than 6 decimal places.",
    E312: "Two mandates for the same principal in a goal.",
    E313: "Two spend lines for the same category in a mandate.",
    E314: "Two rules with the same subject in a goal.",
    E315: "`on_close: transfer` targets itself or an unknown goal.",
    E316: "Amendment deadlock.",
    E317: "Steward circle has no holders.",
    E319: "Duration must be > 0.",
    E322: "`approve(members, …)` is not allowed.",
    E323: "Duplicate holder in a circle.",
    W401: "Mandate `expires` is in the past.",
    W402: "`else allow` on a rule or `amend`.",
    W403: "A mandate's spend limit exceeds the goal's `fund` for the same period.",
    W404: "`on_underfunded` given but the goal has no `fund`.",
    W405: "`per_request` exceeds every spend limit of the mandate.",
    W406: "Agent declared but holds no mandate in any goal.",
    W408: "Duplicate capability.",
}

impl Code {
    /// The severity implied by the code's letter.
    pub const fn severity(self) -> Severity {
        match self.as_str().as_bytes()[0] {
            b'W' => Severity::Warning,
            _ => Severity::Error,
        }
    }
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One problem found in a source, serialized exactly as SPEC-01 §5:
/// `{"code","severity","message","span","notes"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    /// Stable code; tests and clients match on this, not on `message`.
    pub code: Code,
    /// Derived from `code`.
    pub severity: Severity,
    /// Human-readable, single line.
    pub message: String,
    /// The offending source text.
    pub span: Span,
    /// Extra hints, e.g. "did you mean `core`?".
    pub notes: Vec<String>,
}

impl Diagnostic {
    /// A diagnostic with the severity implied by `code` and no notes.
    pub fn new(code: Code, message: impl Into<String>, span: Span) -> Diagnostic {
        Diagnostic {
            code,
            severity: code.severity(),
            message: message.into(),
            span,
            notes: Vec::new(),
        }
    }

    /// Adds a note.
    #[must_use]
    pub fn with_note(mut self, note: impl Into<String>) -> Diagnostic {
        self.notes.push(note.into());
        self
    }

    /// Whether this diagnostic is an error.
    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }
}
