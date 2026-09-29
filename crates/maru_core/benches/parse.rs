//! `cargo bench -p maru_core --bench parse`: time to parse a generated 2,000-line spec.
//! L01 acceptance target is < 5 ms; this reports, it does not gate.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::hint::black_box;
use std::time::{Duration, Instant};

/// Builds a valid spec of at least `lines` lines from lumen-like goals.
fn generated_spec(lines: usize) -> String {
    let mut src = String::from(
        "# Generated benchmark spec\norg \"Bench\" {\n  purpose \"Benchmark the parser.\"\n  members: invite(sponsors: 1)\n  amend: vote(core, 2/3) within 7d else deny\n\n  circle core {\n    seats: 3\n    term: 1y\n    holders: @mina, @jo\n  }\n\n  agent builder {\n    operator: @mina\n    runtime: hosted\n  }\n",
    );
    let mut n = 0;
    while src.lines().count() + 1 < lines {
        src.push_str(&format!(
            r#"
  # goal {n}
  goal editor_{n} "Open cloud image editor {n}" {{
    steward: core
    purpose "Ship a usable editor with layers, masks and export."
    fund: usd 12_000 / month from treasury
    on_underfunded: pause
    on_close: return treasury
    success: metric(weekly_active_users) >= 10_000 by 2027-06-30

    mandate builder {{
      spend llm <= usd 4_000 / month
      spend compute <= usd 1_000.50 / month
      per_request <= usd 25
      can: claim_tasks, post_evidence, report_metric(weekly_active_users)
      expires: 2027-01-01
    }}

    rule spend > usd 500 requires approve(core, 1) within 48h else deny # large spends
    rule close requires vote(core, 2/3) within 7d else deny
  }}
"#
        ));
        n += 1;
    }
    src.push_str("}\n");
    src
}

fn main() {
    let src = generated_spec(2_000);
    let lines = src.lines().count();
    let out = maru_core::parse(&src);
    assert!(out.diagnostics.is_empty(), "{:?}", out.diagnostics);

    for _ in 0..20 {
        black_box(maru_core::parse(black_box(&src)));
    }
    let mut times: Vec<Duration> = (0..200)
        .map(|_| {
            let start = Instant::now();
            black_box(maru_core::parse(black_box(&src)));
            start.elapsed()
        })
        .collect();
    times.sort();
    let median = times[times.len() / 2];
    println!(
        "parse: {lines} lines, {} bytes: median {:.3} ms, min {:.3} ms, max {:.3} ms (target < 5 ms)",
        src.len(),
        median.as_secs_f64() * 1e3,
        times[0].as_secs_f64() * 1e3,
        times[times.len() - 1].as_secs_f64() * 1e3,
    );
}
