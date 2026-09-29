//! wasm-bindgen bindings for `maru_core`, built with `wasm-pack build --target web` into
//! `web/packages/maru-wasm` (`@openmaru/maru-wasm`).

use wasm_bindgen::prelude::*;

/// `maru_core::version()`.
#[wasm_bindgen]
pub fn version() -> String {
    maru_core::version().to_owned()
}

/// `maru_core::echo_json()`; throws `Error("invalid JSON: …")` on invalid input.
#[wasm_bindgen]
pub fn echo_json(input: &str) -> Result<String, JsError> {
    maru_core::echo_json(input).map_err(|e| JsError::new(&e.to_string()))
}

/// Whether `maru_core` was built with `authz` (always `false` for the WASM package).
#[wasm_bindgen]
pub fn authz_enabled() -> bool {
    maru_core::authz_enabled()
}
