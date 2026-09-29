//! T03-T09 (extra): the `authz` feature is on by default (off only for WASM builds).

// T03-T09
#[test]
fn t03_t09_authz_feature_is_on_by_default() {
    assert!(maru_core::authz_enabled());
}
