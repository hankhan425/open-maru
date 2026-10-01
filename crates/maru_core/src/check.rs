//! The checker (SPEC-01 §5): validates a source and lowers it to the IR (SPEC-01 §6).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::diag::Diagnostic;
use crate::ir::Ir;

/// Options for [`check`].
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct CheckOptions {
    /// The current time. Enables time-relative warnings (W401); without it they are
    /// skipped so checking stays deterministic.
    pub now: Option<DateTime<Utc>>,
}

/// The result of [`check`]: `{"diagnostics": […], "ir": {…} | null}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckOutput {
    /// Errors and warnings, sorted by span start.
    pub diagnostics: Vec<Diagnostic>,
    /// The IR, present exactly when there are no errors.
    pub ir: Option<Ir>,
}

/// Checks `src` and, when it has no errors, lowers it to the IR.
pub fn check(_src: &str, _opts: &CheckOptions) -> CheckOutput {
    unimplemented!("L03")
}
