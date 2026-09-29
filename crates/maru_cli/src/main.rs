//! `maru`: the maru command-line tool.
#![forbid(unsafe_code)]

use std::io::{self, Read, Write};
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// maru language tools.
#[derive(Debug, Parser)]
#[command(name = "maru", version = maru_core::version(), about, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Canonicalize JSON from stdin (sorted keys, no whitespace). Binding harness.
    #[command(name = "echo-json", hide = true)]
    EchoJson,
}

fn main() -> ExitCode {
    match Cli::parse().command {
        Command::EchoJson => echo_json(),
    }
}

fn echo_json() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut input) {
        eprintln!("error: reading stdin: {e}");
        return ExitCode::FAILURE;
    }
    match maru_core::echo_json(&input) {
        Ok(output) => match writeln!(io::stdout(), "{output}") {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: writing stdout: {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
