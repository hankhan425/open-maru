//! IR → Cedar policies (SPEC-04 §2.1).

use cedar_policy::PolicySet;
use thiserror::Error;

use crate::ir::Ir;

/// Why an IR does not compile. The checker never produces such an IR; these guard IRs
/// built or edited elsewhere.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CompileError {
    /// `ir_version` is not [`IR_VERSION`](crate::ir::IR_VERSION).
    #[error("unsupported IR version {0}")]
    UnsupportedIrVersion(u32),
    /// An id, handle, metric name, rule id, date or amount is not one the language allows.
    #[error("invalid {what} `{value}` in the IR")]
    InvalidIr {
        /// What the value is (`"goal id"`, `"handle"`, …).
        what: &'static str,
        /// The value.
        value: String,
    },
    /// Two generated policies would have the same id.
    #[error("two policies would have the id `{0}`")]
    DuplicatePolicyId(String),
    /// A generated policy does not parse (a bug).
    #[error("generated policy `{id}` does not parse: {message}")]
    Policy {
        /// The policy id.
        id: String,
        /// Cedar's message.
        message: String,
    },
    /// The generated policies do not validate against the schema in strict mode (a bug).
    #[error("generated policies do not validate against the Cedar schema: {0}")]
    Validation(String),
    /// The bundled Cedar schema does not parse (a bug).
    #[error("the Cedar schema does not parse: {0}")]
    Schema(String),
}

/// A compiled policy set plus the IR index `decide` explains denials with. Built once per
/// spec version.
#[derive(Debug, Clone)]
pub struct CompiledPolicy {}

impl CompiledPolicy {
    /// Policy ids, in the order of [`cedar_text`].
    pub fn policy_ids(&self) -> Vec<&str> {
        unimplemented!("L06")
    }

    /// The whole Cedar policy set.
    pub fn policy_set(&self) -> &PolicySet {
        unimplemented!("L06")
    }
}

/// Compiles `ir` into a policy set validated against [`CEDAR_SCHEMA`](super::CEDAR_SCHEMA)
/// in strict mode.
///
/// # Errors
///
/// [`CompileError`] when the IR holds values the language does not allow, or two policies
/// would share an id.
pub fn compile(_ir: &Ir) -> Result<CompiledPolicy, CompileError> {
    unimplemented!("L06")
}

/// The Cedar policies for `ir` as text, for snapshots and the "Source → policy" view.
pub fn cedar_text(_ir: &Ir) -> String {
    unimplemented!("L06")
}
