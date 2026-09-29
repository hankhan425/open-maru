//! Rustler NIF bindings for `maru_core`, loaded by `Openmaru.Lang.Native`. Every NIF
//! runs on a dirty CPU scheduler.

use rustler::{Atom, Binary};

mod atoms {
    rustler::atoms! {
        invalid_json,
    }
}

/// `maru_core::version/0`.
#[rustler::nif(schedule = "DirtyCpu")]
fn version() -> &'static str {
    maru_core::version()
}

/// `maru_core::echo_json/1`: `{:ok, json}` or `{:error, {:invalid_json, message}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn echo_json(input: Binary) -> Result<String, (Atom, String)> {
    let input = std::str::from_utf8(input.as_slice())
        .map_err(|e| (atoms::invalid_json(), format!("input is not UTF-8: {e}")))?;
    maru_core::echo_json(input).map_err(|e| (atoms::invalid_json(), e.to_string()))
}

/// Panics on purpose, to prove panics surface as errors instead of crashing the VM.
#[cfg(feature = "test-helpers")]
#[rustler::nif(schedule = "DirtyCpu")]
fn panic_test() -> Atom {
    panic!("panic_test: deliberate panic")
}

rustler::init!("Elixir.Openmaru.Lang.Native");
