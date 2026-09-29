//! T03-T01, T03-T02: version and `echo_json` vectors.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use maru_core::{CoreError, echo_json, version};
use proptest::prelude::*;
use serde::Deserialize;

#[derive(Deserialize)]
struct Vector {
    input: String,
    output: String,
}

fn vectors() -> Vec<Vector> {
    serde_json::from_str(include_str!("vectors/echo.json")).expect("echo.json parses")
}

// T03-T01
#[test]
fn t03_t01_version_equals_cargo_pkg_version() {
    assert_eq!(version(), env!("CARGO_PKG_VERSION"));
}

// T03-T02
#[test]
fn t03_t02_echo_json_vectors_pass() {
    let vectors = vectors();
    assert!(!vectors.is_empty());
    for v in vectors {
        assert_eq!(echo_json(&v.input).as_deref(), Ok(v.output.as_str()), "input: {:?}", v.input);
    }
}

// T03-T02
#[test]
fn t03_t02_invalid_json_is_invalid_json_error() {
    let deep = "[".repeat(200) + &"]".repeat(200);
    for input in ["", "   ", "{", "[1,]", "{\"a\":1} x", "nul", "'a'", "{a:1}", "01", "NaN", &deep] {
        assert!(
            matches!(echo_json(input), Err(CoreError::InvalidJson(_))),
            "accepted {input:?}"
        );
    }
}

// T03-T02
#[test]
fn t03_t02_invalid_json_error_carries_a_message() {
    let err = echo_json("{").unwrap_err();
    assert!(err.to_string().starts_with("invalid JSON: "), "{err}");
}

fn json_value() -> impl Strategy<Value = serde_json::Value> {
    let leaf = prop_oneof![
        Just(serde_json::Value::Null),
        any::<bool>().prop_map(serde_json::Value::from),
        any::<i64>().prop_map(serde_json::Value::from),
        "[a-zA-Z0-9 _é😀\\\\\"\n]{0,8}".prop_map(serde_json::Value::from),
    ];
    leaf.prop_recursive(4, 64, 8, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..8).prop_map(serde_json::Value::from),
            prop::collection::btree_map("[a-zA-Z_]{0,6}", inner, 0..8)
                .prop_map(|m| serde_json::Value::Object(m.into_iter().collect())),
        ]
    })
}

proptest! {
    // T03-T02 (property): output is canonical — idempotent, whitespace-free, same value.
    #[test]
    fn t03_t02_echo_json_is_canonical(value in json_value()) {
        let pretty = serde_json::to_string_pretty(&value).unwrap();
        let once = echo_json(&pretty).unwrap();
        prop_assert_eq!(echo_json(&once).unwrap(), once.clone());
        prop_assert_eq!(serde_json::from_str::<serde_json::Value>(&once).unwrap(), value);
    }
}
