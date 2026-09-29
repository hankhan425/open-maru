use thiserror::Error;

/// Errors returned by `maru_core`.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    /// The input is not valid JSON; carries the parser's message.
    #[error("invalid JSON: {0}")]
    InvalidJson(String),
}
