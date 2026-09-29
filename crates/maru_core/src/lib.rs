//! maru language core. One implementation compiled to three targets: the Rustler NIF
//! (`maru_nif`), WASM (`maru_wasm`), and the `maru` CLI (`maru_cli`).
#![forbid(unsafe_code)]
#![warn(missing_docs)]

mod error;

pub use error::CoreError;

/// The crate version (`CARGO_PKG_VERSION`).
pub fn version() -> &'static str {
    unimplemented!()
}

/// Parses `input` as JSON and re-serializes it with object keys sorted and no whitespace.
///
/// # Errors
///
/// [`CoreError::InvalidJson`] when `input` is not a single valid JSON value.
pub fn echo_json(_input: &str) -> Result<String, CoreError> {
    unimplemented!()
}

/// Whether this build includes the `authz` feature (Cedar policy evaluation).
pub const fn authz_enabled() -> bool {
    unimplemented!()
}
