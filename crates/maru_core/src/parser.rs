//! Recursive-descent parser for maru-lang v0 (SPEC-01 §3) with error recovery.

use crate::ast::File;
use crate::diag::Diagnostic;

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
pub fn parse(_src: &str) -> ParseOutput {
    unimplemented!()
}
