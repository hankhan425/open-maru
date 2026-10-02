//! maru language core. One implementation compiled to three targets: the Rustler NIF
//! (`maru_nif`), WASM (`maru_wasm`), and the `maru` CLI (`maru_cli`).
//!
//! Feature `authz` (default) is reserved for the Cedar compiler and `decide`; the WASM
//! build disables it.
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod ast;
pub mod charter;
pub mod check;
pub mod diag;
mod error;
pub mod fmt;
pub mod human;
pub mod ir;
pub mod lexer;
pub mod limits;
pub mod parser;
pub mod span;
pub mod suggest;

pub use charter::{Section, render_markdown, render_sections};
pub use check::{CheckOptions, CheckOutput, check};
pub use diag::{Code, Diagnostic, Severity};
pub use error::CoreError;
pub use fmt::{format, source_hash};
pub use ir::Ir;
pub use parser::{ParseOutput, parse};
pub use span::{Pos, Span};

use serde_json::{Map, Value};

/// The crate version (`CARGO_PKG_VERSION`).
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Whether this build includes the `authz` feature (Cedar policy evaluation).
pub const fn authz_enabled() -> bool {
    cfg!(feature = "authz")
}

/// Parses `input` as JSON and re-serializes it with object keys sorted (by bytes) and
/// no whitespace. Duplicate keys keep the last value.
///
/// # Errors
///
/// [`CoreError::InvalidJson`] when `input` is not a single valid JSON value.
pub fn echo_json(input: &str) -> Result<String, CoreError> {
    let value: Value =
        serde_json::from_str(input).map_err(|e| CoreError::InvalidJson(e.to_string()))?;
    serde_json::to_string(&sort_keys(value)).map_err(|e| CoreError::InvalidJson(e.to_string()))
}

/// Rebuilds objects in sorted key order, so output is sorted even if some dependency
/// enables serde_json's `preserve_order` feature.
fn sort_keys(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(
                entries
                    .into_iter()
                    .map(|(k, v)| (k, sort_keys(v)))
                    .collect::<Map<_, _>>(),
            )
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sort_keys).collect()),
        other => other,
    }
}
