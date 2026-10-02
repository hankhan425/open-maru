//! `decide` (SPEC-04 §3).

use super::compile::CompiledPolicy;
use super::{Decision, DecisionRequest};

/// Answers `req` under `policy` (SPEC-04 §3).
pub fn decide(_policy: &CompiledPolicy, _req: &DecisionRequest) -> Decision {
    unimplemented!("L06")
}
