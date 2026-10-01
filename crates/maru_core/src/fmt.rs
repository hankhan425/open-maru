//! Canonical formatter for maru-lang v0 (SPEC-01 §7). Not implemented yet.

use crate::diag::Diagnostic;

/// Formats `src` canonically.
///
/// # Errors
///
/// The parse diagnostics when `src` has syntax errors.
pub fn format(src: &str) -> Result<String, Vec<Diagnostic>> {
    let _ = src;
    unimplemented!("L02 formatter")
}

/// `"sha256:<hex>"` of [`format`]`(src)`.
///
/// # Errors
///
/// The parse diagnostics when `src` has syntax errors.
pub fn source_hash(src: &str) -> Result<String, Vec<Diagnostic>> {
    let _ = src;
    unimplemented!("L02 source hash")
}

/// The canonical text of a rule: its formatted line without indentation or comments.
pub fn rule_line(rule: &crate::ast::Rule) -> String {
    let _ = rule;
    unimplemented!("L02 rule line")
}
