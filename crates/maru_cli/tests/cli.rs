//! T03-T08: `maru` CLI surface.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use assert_cmd::Command;
use serde::Deserialize;

fn maru() -> Command {
    Command::cargo_bin("maru").unwrap()
}

// T03-T08
#[test]
fn t03_t08_version_prints_maru_and_version() {
    let out = maru().arg("--version").assert().success();
    let stdout = String::from_utf8(out.get_output().stdout.clone()).unwrap();
    assert_eq!(stdout, format!("maru {}\n", maru_core::version()));
}

// T03-T08
#[test]
fn t03_t08_help_exits_zero() {
    let out = maru().arg("--help").assert().success();
    let stdout = String::from_utf8(out.get_output().stdout.clone()).unwrap();
    assert!(stdout.contains("Usage: maru"), "{stdout}");
}

// T03-T08
#[test]
fn t03_t08_unknown_subcommand_exits_2() {
    maru().arg("nope").assert().code(2);
}

#[derive(Deserialize)]
struct Vector {
    input: String,
    output: String,
}

// T03-T08 (extra): the CLI target produces the shared echo vectors byte-for-byte.
#[test]
fn t03_t08_echo_json_vectors_via_cli() {
    let vectors: Vec<Vector> =
        serde_json::from_str(include_str!("../../maru_core/tests/vectors/echo.json")).unwrap();
    for v in vectors {
        maru()
            .arg("echo-json")
            .write_stdin(v.input.clone())
            .assert()
            .success()
            .stdout(format!("{}\n", v.output));
    }
}

// T03-T08 (extra): invalid JSON exits 1 with the error on stderr.
#[test]
fn t03_t08_echo_json_invalid_exits_1() {
    let out = maru().arg("echo-json").write_stdin("{").assert().code(1);
    let stderr = String::from_utf8(out.get_output().stderr.clone()).unwrap();
    assert!(stderr.contains("invalid JSON"), "{stderr}");
    assert!(out.get_output().stdout.is_empty());
}
