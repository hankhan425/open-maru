//! L06: the Cedar compiler and `decide` (SPEC-04 §2–§3).
//!
//! The decision cases (T03..T18) live in `support/decide_cases.rs`, which also writes
//! `tests/vectors/decide.json` (T21). Regenerate the vectors with
//! `UPDATE_VECTORS=1 cargo test -p maru_core --test authz` and review the diff.
#![cfg(feature = "authz")]
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use std::collections::BTreeMap;
use std::str::FromStr;
use std::time::{Duration, Instant};

use cedar_policy::{Effect, PolicySet, Schema, ValidationMode, Validator};
use maru_core::ast::MAX_MONEY_MICROS;
use maru_core::authz::{
    Action, CEDAR_SCHEMA, CompileError, Decision, DecisionRequest, DenyReason, cedar_text, compile,
    decide,
};
use maru_core::{CheckOptions, Ir, check};
use serde_json::{Value, json};
use support::checking::{ir_ok, is_rule_id, rule_id};
use support::decide_cases::*;

const GOLDEN_CEDAR: &str = include_str!("snapshots/lumen.cedar");
const VECTORS_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/decide.json");

/// The schema file, read at run time.
fn schema() -> Schema {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/schema/openmaru.cedarschema");
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {path}: {e}"));
    Schema::from_cedarschema_str(&text)
        .unwrap_or_else(|e| panic!("schema does not parse: {e:?}"))
        .0
}

/// Asserts `set` validates against the schema in strict mode, without warnings.
fn assert_validates(set: &PolicySet) {
    let result = Validator::new(schema()).validate(set, ValidationMode::Strict);
    assert!(
        result.validation_passed_without_warnings(),
        "strict validation failed:\n{result}"
    );
}

/// Asserts every case of `id` decides as expected.
fn assert_cases(id: &str) {
    for case in cases_for(id) {
        let policy = compile(&fixture_ir(case.ir_fixture)).unwrap();
        assert_eq!(
            decide(&policy, &case.request),
            case.expected,
            "{}\nrequest: {:#?}",
            case.name,
            case.request
        );
    }
}

/// `decide` under `ir` for each `(request, expected)`.
fn assert_decisions(ir: &Ir, expectations: Vec<(DecisionRequest, Decision)>) {
    let policy = compile(ir).unwrap();
    for (request, expected) in expectations {
        assert_eq!(decide(&policy, &request), expected, "request: {request:#?}");
    }
}

/// The `@id("…")` values in `text`, in order.
fn text_ids(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| l.strip_prefix("@id(\""))
        .map(|rest| rest.split('"').next().unwrap().to_string())
        .collect()
}

// ---- compiling ----

// L06-T01
#[test]
fn l06_t01_lumen_cedar_text_matches_the_snapshot_and_validates_strictly() {
    let ir = fixture_ir("lumen.maru");
    let text = cedar_text(&ir);
    assert_eq!(
        text, GOLDEN_CEDAR,
        "cedar_text(lumen) differs from tests/snapshots/lumen.cedar:\n{text}"
    );
    let set = PolicySet::from_str(&text).unwrap();
    assert_eq!(set.policies().count(), 12);
    assert_validates(&set);

    let compiled = compile(&ir).unwrap();
    assert_validates(compiled.policy_set());
    assert_eq!(compiled.policy_set().policies().count(), 12);
}

// L06-T02
#[test]
fn l06_t02_policy_ids_are_deterministic_and_follow_the_naming() {
    let ir = fixture_ir("lumen.maru");
    let LumenRules { over_500, expense } = lumen_rules();
    assert_eq!(
        over_500,
        rule_id(
            "editor",
            "rule spend > usd 500 requires approve(core, 1) within 48h else deny"
        )
    );
    assert_eq!(
        expense,
        rule_id(
            "editor",
            "rule spend expense requires approve(core, 1) within 7d else deny"
        )
    );
    let expected = vec![
        "steward:editor",
        "steward-session:editor:builder",
        "mandate:editor:agent:builder:caps",
        "mandate:editor:agent:builder:metrics",
        "mandate:editor:agent:builder:spend:llm",
        "mandate:editor:agent:builder:spend:compute",
        "mandate:editor:person:jo:caps",
        "mandate:editor:person:jo:spend:expense",
        over_500.as_str(),
        expense.as_str(),
        "operator:builder",
        "self:jo",
    ];
    let first = compile(&ir).unwrap();
    let second = compile(&ir).unwrap();
    assert_eq!(first.policy_ids(), expected);
    assert_eq!(second.policy_ids(), expected);
    assert_eq!(text_ids(&cedar_text(&ir)), expected);

    // Only approval rules are forbids, and they carry `@approval` with their id.
    for policy in first.policy_set().policies() {
        let id = policy.id().as_ref();
        assert_eq!(policy.annotation("id"), Some(id), "@id of {id}");
        let is_rule = is_rule_id(id);
        assert_eq!(
            policy.annotation("approval"),
            is_rule.then_some(id),
            "@approval of {id}"
        );
        assert_eq!(policy.effect() == Effect::Forbid, is_rule, "effect of {id}");
    }

    // The same spec written differently compiles to the same text.
    let messy = ir_ok(include_str!("fixtures/lumen.messy.maru"));
    assert_eq!(cedar_text(&messy), cedar_text(&ir));
}

// ---- decisions (cases in support/decide_cases.rs) ----

// L06-T03
#[test]
fn l06_t03_builder_spends_10_on_llm() {
    assert_cases("L06-T03");
}

// L06-T04
#[test]
fn l06_t04_builder_spends_30_on_llm_over_the_per_request_cap() {
    assert_cases("L06-T04");
}

// L06-T05
#[test]
fn l06_t05_builder_spends_on_expense_without_a_line() {
    assert_cases("L06-T05");
}

// L06-T06
#[test]
fn l06_t06_builder_spends_after_its_mandate_expires() {
    assert_cases("L06-T06");
}

// L06-T07
#[test]
fn l06_t07_jo_expense_requires_the_expense_rule() {
    assert_cases("L06-T07");
}

// L06-T08
#[test]
fn l06_t08_jo_expense_with_the_rule_approved_is_allowed() {
    assert_cases("L06-T08");
}

// L06-T09
#[test]
fn l06_t09_jo_large_expense_requires_both_rules_sorted() {
    assert_cases("L06-T09");
    let LumenRules { over_500, expense } = lumen_rules();
    let Decision::RequiresApproval { rule_ids } = &cases_for("L06-T09")[0].expected else {
        panic!("T09 expects RequiresApproval");
    };
    assert_eq!(rule_ids.len(), 2);
    assert!(rule_ids.contains(&over_500) && rule_ids.contains(&expense));
    assert!(
        rule_ids.windows(2).all(|w| w[0] < w[1]),
        "sorted: {rule_ids:?}"
    );
}

// L06-T10
#[test]
fn l06_t10_jo_large_expense_with_one_rule_approved_requires_the_other() {
    assert_cases("L06-T10");
}

// L06-T11
#[test]
fn l06_t11_stewardship_grants_no_spend() {
    assert_cases("L06-T11");
}

// L06-T12
#[test]
fn l06_t12_review_needs_an_effective_steward_holder() {
    assert_cases("L06-T12");
}

// L06-T13
#[test]
fn l06_t13_task_capabilities() {
    assert_cases("L06-T13");
}

// L06-T14
#[test]
fn l06_t14_metric_reports() {
    assert_cases("L06-T14");
}

// L06-T15
#[test]
fn l06_t15_issuing_tokens() {
    assert_cases("L06-T15");
}

// L06-T16
#[test]
fn l06_t16_starting_sessions() {
    assert_cases("L06-T16");
}

// L06-T17
#[test]
fn l06_t17_a_category_rule_gates_only_its_category() {
    assert_cases("L06-T17");
    assert_eq!(
        llm_gate_rule(),
        rule_id(
            "editor",
            "rule spend llm > usd 100 requires approve(core, 1)"
        )
    );
}

// L06-T18
#[test]
fn l06_t18_unknown_principal_and_unknown_goal() {
    assert_cases("L06-T18");
}

// ---- vectors ----

/// `decide.json`: one case per line.
fn vectors_json(cases: &[Case]) -> String {
    let mut out = String::from("{\n");
    out.push_str(&format!(
        "  \"generated_by\": {},\n  \"cases\": [\n",
        serde_json::to_string(
            "crates/maru_core/tests/authz.rs (L06-T21); regenerate with \
             UPDATE_VECTORS=1 cargo test -p maru_core --test authz"
        )
        .unwrap()
    ));
    let lines: Vec<String> = cases
        .iter()
        .map(|c| format!("    {}", serde_json::to_string(c).unwrap()))
        .collect();
    out.push_str(&lines.join(",\n"));
    out.push_str("\n  ]\n}\n");
    out
}

// L06-T21
#[test]
fn l06_t21_decide_vectors_match_the_cases() {
    let cases = cases();
    for n in 3..=18 {
        let id = format!("L06-T{n:02} ");
        assert!(
            cases.iter().any(|c| c.name.starts_with(&id)),
            "no case for {id}"
        );
    }
    let generated = vectors_json(&cases);
    if std::env::var_os("UPDATE_VECTORS").is_some() {
        std::fs::write(VECTORS_PATH, &generated).unwrap();
    }
    let committed = std::fs::read_to_string(VECTORS_PATH)
        .unwrap_or_else(|e| panic!("reading {VECTORS_PATH}: {e}"));
    assert!(
        committed == generated,
        "tests/vectors/decide.json drifted from the cases; regenerate with \
         UPDATE_VECTORS=1 cargo test -p maru_core --test authz\n{generated}"
    );

    // The committed vectors, read back as consumers read them, decide as expected.
    let doc: Value = serde_json::from_str(&committed).unwrap();
    let vectors = doc["cases"].as_array().unwrap();
    assert_eq!(vectors.len(), cases.len());
    for v in vectors {
        let fixture = v["ir_fixture"].as_str().unwrap();
        let request: DecisionRequest = serde_json::from_value(v["request"].clone()).unwrap();
        let expected: Decision = serde_json::from_value(v["expected"].clone()).unwrap();
        let policy = compile(&fixture_ir(fixture)).unwrap();
        assert_eq!(decide(&policy, &request), expected, "{}", v["name"]);
    }
}

// ---- performance ----

/// A valid spec of at least `lines` lines: lumen-like goals over 10 circles, 10 agents
/// and 20 people.
fn generated_spec(lines: usize) -> String {
    let mut src = String::from("org \"Bench\" {\n  amend: approve(c0, 1)\n");
    for c in 0..10 {
        src.push_str(&format!(
            "\n  circle c{c} {{\n    seats: 3\n    holders: @p{}, @p{}\n  }}\n",
            2 * c,
            2 * c + 1
        ));
    }
    for a in 0..10 {
        src.push_str(&format!(
            "\n  agent a{a} {{\n    operator: @p{}\n    runtime: hosted\n  }}\n",
            a * 2
        ));
    }
    let mut n = 0;
    while src.lines().count() + 1 < lines {
        let c = n % 10;
        src.push_str(&format!(
            r#"
  goal g{n} "Goal {n}" {{
    steward: c{c}
    fund: usd 12_000 / month from treasury

    mandate a{a} {{
      spend llm <= usd 4_000 / month
      spend compute <= usd 1_000 / month
      per_request <= usd 25
      can: claim_tasks, post_evidence, report_metric(weekly_active_users)
      expires: 2027-01-01
    }}

    mandate @p{p} {{
      spend expense <= usd 500 / month
      can: claim_tasks, create_tasks, post_evidence
    }}

    rule spend > usd 500 requires approve(c{c}, 1) within 48h else deny
    rule spend expense requires approve(c{c}, 1) within 7d else deny
    rule close requires vote(c{c}, 2/3) within 7d else deny
  }}
"#,
            a = n % 10,
            p = (n * 7) % 20,
        ));
        n += 1;
    }
    src.push_str("}\n");
    src
}

// L06-T22
#[test]
#[ignore = "benchmark: cargo test --release -p maru_core --test authz -- --ignored l06_t22"]
fn l06_t22_decide_p95_under_2ms_on_a_2000_line_spec() {
    let src = generated_spec(2_000);
    let lines = src.lines().count();
    assert!(lines >= 2_000, "{lines} lines");
    let out = check(&src, &CheckOptions::default());
    let ir = out.ir.unwrap_or_else(|| panic!("{:#?}", out.diagnostics));
    let goals = ir.org.goals.len();

    let started = Instant::now();
    let policy = compile(&ir).unwrap();
    let compile_time = started.elapsed();

    let holders: BTreeMap<String, Vec<String>> = (0..10)
        .map(|c| {
            (
                format!("c{c}"),
                vec![format!("p{}", 2 * c), format!("p{}", 2 * c + 1)],
            )
        })
        .collect();
    let mut times = Vec::with_capacity(10_000);
    let mut seen = BTreeMap::<&'static str, usize>::new();
    for i in 0..10_000usize {
        // Mostly the goal's own mandate holders and stewards, sometimes anyone.
        let n = (i * 31) % goals;
        let g = format!("g{n}");
        let principal = match i % 4 {
            0 => agent(&format!("a{}", n % 10)),
            1 => person(&format!("p{}", (n * 7) % 20)),
            2 => person(&format!("p{}", 2 * (n % 10))),
            _ => person(&format!("p{}", i % 20)),
        };
        let action = Action::ALL[i % Action::ALL.len()];
        let resource = match action {
            Action::IssueToken | Action::StartSession => agent_resource(&format!("a{}", i % 10)),
            _ => goal(&g),
        };
        let category = ["llm", "compute", "expense"][i % 3];
        let request = req(principal, action, resource)
            .category(category, usd((i % 700) as u64))
            .metric("weekly_active_users")
            .for_goal(&g)
            .holders(holders.clone());
        let started = Instant::now();
        let decision = decide(&policy, &request);
        times.push(started.elapsed());
        let kind = match decision {
            Decision::Allow => "allow",
            Decision::Deny { .. } => "deny",
            Decision::RequiresApproval { .. } => "requires_approval",
        };
        *seen.entry(kind).or_default() += 1;
    }
    times.sort();
    let p50 = times[times.len() / 2];
    let p95 = times[times.len() * 95 / 100];
    let max = times[times.len() - 1];
    eprintln!(
        "L06-T22: {lines} lines, {goals} goals, {} policies; compile {compile_time:?}; \
         decide p50 {p50:?}, p95 {p95:?}, max {max:?}; {seen:?}",
        policy.policy_ids().len()
    );
    assert_eq!(
        seen.len(),
        3,
        "the requests should reach every outcome: {seen:?}"
    );
    assert!(p95 < Duration::from_millis(2), "p95 {p95:?}");
}

// ---- edge cases ----

// L07 caches one compiled policy per spec version and calls `decide` from many
// processes.
#[test]
fn l06_compiled_policy_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<maru_core::CompiledPolicy>();
    let policy = std::sync::Arc::new(compile(&fixture_ir("lumen.maru")).unwrap());
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let policy = std::sync::Arc::clone(&policy);
            std::thread::spawn(move || {
                cases_for("L06-T09")
                    .into_iter()
                    .all(|c| decide(&policy, &c.request) == c.expected)
            })
        })
        .collect();
    assert!(handles.into_iter().all(|h| h.join().unwrap()));
}

/// A spec with a byo agent holding only metric capabilities, a hosted agent with
/// mandates in two goals, a person with mandates in two goals, a rule with neither
/// category nor threshold, and a second circle.
const MULTI: &str = r#"org "Multi" {
  amend: approve(core, 1)

  circle core {
    seats: 2
    holders: @mina, @jo
  }

  circle ops {
    seats: 1
    holders: @sam
  }

  agent scout {
    operator: @jo
  }

  agent builder {
    operator: @mina
    runtime: hosted
  }

  goal editor "Editor" {
    steward: core

    mandate scout {
      can: report_metric(downloads), report_metric(stars)
    }

    mandate builder {
      spend compute <= usd 10 / day
    }

    mandate @sam {
      spend llm <= usd 5 / week
      per_request <= usd 1
    }

    rule spend requires approve(core, 1)
  }

  goal site "Site" {
    steward: ops

    mandate @sam {
      can: create_tasks
      expires: 2027-03-01
    }

    mandate builder {
      can: claim_tasks
    }
  }
}
"#;

/// 2027-03-01T00:00:00Z: @sam's mandate in `site` expires then.
const MAR_2027: i64 = 1_803_859_200;

#[test]
fn l06_policies_for_byo_agents_shared_people_and_bare_rules() {
    let ir = ir_ok(MULTI);
    let any_spend = ir.org.goals[0].rules[0].id.clone();
    assert_eq!(
        any_spend,
        rule_id("editor", "rule spend requires approve(core, 1)")
    );
    let policy = compile(&ir).unwrap();
    assert_eq!(
        policy.policy_ids(),
        vec![
            "steward:editor",
            "steward-session:editor:builder",
            "mandate:editor:agent:scout:metrics",
            "mandate:editor:agent:builder:spend:compute",
            "mandate:editor:person:sam:spend:llm",
            any_spend.as_str(),
            "steward:site",
            "steward-session:site:builder",
            "mandate:site:person:sam:caps",
            "mandate:site:agent:builder:caps",
            "operator:scout",
            "operator:builder",
            "self:sam",
        ]
    );
    assert_validates(policy.policy_set());
    let text = cedar_text(&ir);
    assert_validates(&PolicySet::from_str(&text).unwrap());
    for expected in [
        // Several metrics, no expiry.
        "@id(\"mandate:editor:agent:scout:metrics\")\npermit(principal == Agent::\"scout\", action == Action::\"ReportMetric\", resource == Goal::\"editor\")\nwhen { [\"downloads\", \"stars\"].contains(context.metric) };\n",
        // A rule with neither category nor threshold has no `when`.
        &format!(
            "@id(\"{any_spend}\") @approval(\"{any_spend}\")\nforbid(principal, action == Action::\"Spend\", resource == Goal::\"editor\")\nunless {{ context.approved_rules.contains(\"{any_spend}\") }};\n"
        ),
        // A byo agent's operator still gets both actions (A05 answers `agent_not_hosted`).
        "@id(\"operator:scout\")\npermit(principal == Person::\"jo\",\n       action in [Action::\"IssueToken\", Action::\"StartSession\"],\n       resource == Agent::\"scout\");\n",
        // A single capability is `action ==`; an expiry guards it.
        "@id(\"mandate:site:person:sam:caps\")\npermit(principal == Person::\"sam\", action == Action::\"CreateTask\", resource == Goal::\"site\")\nwhen { context.now_epoch < 1803859200 };\n",
    ] {
        assert!(text.contains(expected), "missing:\n{expected}\nin:\n{text}");
    }

    let core = || holders(&[("core", &["mina", "jo"]), ("ops", &["sam"])]);
    let on = |action, g: &str| req(person("sam"), action, goal(g)).holders(core());
    use DenyReason::*;
    assert_decisions(
        &ir,
        vec![
            // Operators may start sessions for byo agents; stewards may not.
            (
                req(person("jo"), Action::StartSession, agent_resource("scout")),
                allow(),
            ),
            (
                req(
                    person("mina"),
                    Action::StartSession,
                    agent_resource("scout"),
                )
                .for_goal("editor"),
                deny(NotOperator),
            ),
            (
                req(
                    person("jo"),
                    Action::StartSession,
                    agent_resource("builder"),
                )
                .for_goal("site"),
                deny(NotOperator),
            ),
            (
                req(
                    person("sam"),
                    Action::StartSession,
                    agent_resource("builder"),
                )
                .for_goal("site")
                .holders(core()),
                allow(),
            ),
            // A bare rule gates every spend.
            (
                spend(person("sam"), "llm", 1).holders(core()),
                requires(&[&any_spend]),
            ),
            (
                spend(person("sam"), "llm", usd(1))
                    .holders(core())
                    .approved(&[&any_spend]),
                allow(),
            ),
            (
                spend(person("sam"), "llm", usd(1) + 1)
                    .holders(core())
                    .approved(&[&any_spend]),
                deny(PerRequestExceeded),
            ),
            // One self policy covers both of @sam's mandates; @mina holds none.
            (
                req(person("sam"), Action::IssueToken, person_resource("sam")),
                allow(),
            ),
            (
                req(person("mina"), Action::IssueToken, person_resource("mina")),
                deny(NotOperator),
            ),
            (
                req(person("jo"), Action::IssueToken, person_resource("sam")),
                deny(NotOperator),
            ),
            // Stewardship is per goal: @sam stewards site; in editor its mandate lacks
            // the capability.
            (on(Action::ReviewTask, "site"), allow()),
            (on(Action::ReviewTask, "editor"), deny(CapabilityMissing)),
            (
                req(person("sam"), Action::CreateTask, goal("site")).at(MAR_2027 - 1),
                allow(),
            ),
            (
                req(person("sam"), Action::CreateTask, goal("site")).at(MAR_2027),
                deny(MandateExpired),
            ),
            (
                req(person("sam"), Action::ClaimTask, goal("site")),
                deny(CapabilityMissing),
            ),
            // Several metrics.
            (
                req(agent("scout"), Action::ReportMetric, goal("editor")).metric("stars"),
                allow(),
            ),
            (
                req(agent("scout"), Action::ReportMetric, goal("editor")),
                deny(CapabilityMissing),
            ),
            (
                req(agent("scout"), Action::ClaimTask, goal("editor")),
                deny(CapabilityMissing),
            ),
            (
                req(agent("scout"), Action::Spend, goal("editor")).category("llm", 1),
                deny(CategoryNotPermitted),
            ),
        ],
    );
}

#[test]
fn l06_spend_boundaries() {
    use DenyReason::*;
    let LumenRules { over_500, expense } = lumen_rules();
    assert_decisions(
        &fixture_ir("lumen.maru"),
        vec![
            // per_request is inclusive.
            (spend(agent("builder"), "llm", usd(25)), allow()),
            (
                spend(agent("builder"), "llm", usd(25) + 1),
                deny(PerRequestExceeded),
            ),
            (spend(agent("builder"), "compute", usd(25)), allow()),
            (spend(agent("builder"), "llm", 0), allow()),
            // The mandate is valid until 00:00Z on its expiry date.
            (
                spend(agent("builder"), "llm", usd(1)).at(JAN_2027 - 1),
                allow(),
            ),
            (
                spend(agent("builder"), "llm", usd(1)).at(JAN_2027 + 1),
                deny(MandateExpired),
            ),
            // Expired is reported before the per-request cap.
            (
                spend(agent("builder"), "llm", usd(30)).at(JAN_2027),
                deny(MandateExpired),
            ),
            // A category the spec does not know, or none.
            (
                spend(agent("builder"), "travel", 1),
                deny(CategoryNotPermitted),
            ),
            (spend(agent("builder"), "", 1), deny(CategoryNotPermitted)),
            // Thresholds are strict.
            (
                spend(person("jo"), "expense", usd(500)),
                requires(&[&expense]),
            ),
            (
                spend(person("jo"), "expense", usd(500) + 1).approved(&[&expense]),
                requires(&[&over_500]),
            ),
            // Amounts above i64::MAX are over every cap and threshold.
            (
                spend(agent("builder"), "llm", u64::MAX),
                deny(PerRequestExceeded),
            ),
            (
                spend(person("jo"), "expense", u64::MAX),
                requires(&{
                    let mut both = [over_500.as_str(), expense.as_str()];
                    both.sort();
                    both
                }),
            ),
            // Approving unrelated or unknown rules changes nothing.
            (
                spend(person("jo"), "expense", usd(100)).approved(&[&over_500, "x", ""]),
                requires(&[&expense]),
            ),
            // Approval cannot lift a per-request cap.
            (
                spend(agent("builder"), "llm", usd(600)).approved(&[&over_500]),
                deny(PerRequestExceeded),
            ),
        ],
    );
}

#[test]
fn l06_unknown_resources_and_mismatched_kinds_are_forbidden() {
    use DenyReason::*;
    assert_decisions(
        &fixture_ir("lumen.maru"),
        vec![
            (
                req(person("mina"), Action::ReviewTask, goal("nope")),
                deny(Forbidden),
            ),
            (
                req(agent("builder"), Action::ClaimTask, goal("nope")),
                deny(Forbidden),
            ),
            (
                req(agent("builder"), Action::Spend, agent_resource("builder")).category("llm", 1),
                deny(Forbidden),
            ),
            (
                req(person("mina"), Action::ReviewTask, person_resource("jo")),
                deny(Forbidden),
            ),
            (
                req(person("mina"), Action::IssueToken, goal("editor")),
                deny(Forbidden),
            ),
            (
                req(person("mina"), Action::IssueToken, agent_resource("ghost")),
                deny(Forbidden),
            ),
            (
                req(
                    person("mina"),
                    Action::StartSession,
                    person_resource("mina"),
                ),
                deny(Forbidden),
            ),
            // Agents never operate anything.
            (
                req(
                    agent("builder"),
                    Action::IssueToken,
                    agent_resource("builder"),
                ),
                deny(NotOperator),
            ),
            // A person and an agent with the same id are different principals.
            (
                req(person("builder"), Action::ClaimTask, goal("editor")),
                deny(NotSteward),
            ),
            (
                req(agent("jo"), Action::CreateTask, goal("editor"))
                    .holders(holders(&[("core", &["jo"])])),
                deny(NotSteward),
            ),
        ],
    );
}

#[test]
fn l06_steward_powers_come_from_the_effective_holders() {
    use DenyReason::*;
    let ir = fixture_ir("lumen.maru");
    let steward_actions = [
        Action::ClaimTask,
        Action::CreateTask,
        Action::PostEvidence,
        Action::PostGoalEvidence,
        Action::ReportMetric,
        Action::ReviewTask,
        Action::CancelTask,
        Action::PauseGoal,
        Action::ResumeGoal,
        Action::RequestClose,
        Action::ManageSecrets,
    ];
    let mut expectations = Vec::new();
    for action in steward_actions {
        // A holder the request names, even one the spec does not list, is a steward.
        expectations.push((
            req(person("sam"), action, goal("editor")).holders(holders(&[("core", &["sam"])])),
            allow(),
        ));
        // Holding another circle does not count.
        expectations.push((
            req(person("mina"), action, goal("editor")).holders(holders(&[("ops", &["mina"])])),
            deny(NotSteward),
        ));
        expectations.push((
            req(person("mina"), action, goal("editor")).holders(BTreeMap::new()),
            deny(NotSteward),
        ));
    }
    // A steward who also holds a mandate spends only through it.
    expectations.push((
        req(person("jo"), Action::Spend, goal("editor")).category("llm", 1),
        deny(CategoryNotPermitted),
    ));
    // Builder's capabilities lapse with its mandate.
    for action in [
        Action::ClaimTask,
        Action::PostEvidence,
        Action::PostGoalEvidence,
    ] {
        expectations.push((req(agent("builder"), action, goal("editor")), allow()));
        expectations.push((
            req(agent("builder"), action, goal("editor")).at(JAN_2027),
            deny(MandateExpired),
        ));
    }
    expectations.push((
        req(agent("builder"), Action::ReportMetric, goal("editor"))
            .metric("weekly_active_users")
            .at(JAN_2027),
        deny(MandateExpired),
    ));
    // Missing capability is reported before expiry.
    expectations.push((
        req(agent("builder"), Action::ReviewTask, goal("editor")).at(JAN_2027),
        deny(CapabilityMissing),
    ));
    assert_decisions(&ir, expectations);
}

#[test]
fn l06_compile_rejects_irs_the_checker_never_emits() {
    let lumen = fixture_ir("lumen.maru");
    let invalid = |what: &str, edit: &dyn Fn(&mut Ir)| {
        let mut ir = lumen.clone();
        edit(&mut ir);
        match compile(&ir) {
            Err(CompileError::InvalidIr { what: w, .. }) => assert_eq!(w, what),
            other => panic!("expected InvalidIr({what}), got {other:?}"),
        }
        // cedar_text still renders it, safely.
        let text = cedar_text(&ir);
        assert!(PolicySet::from_str(&text).is_ok(), "{text}");
    };
    invalid("goal id", &|ir| ir.org.goals[0].id = "Editor".into());
    invalid("goal id", &|ir| {
        ir.org.goals[0].id = "editor\"), resource == Goal::\"x".into()
    });
    invalid("circle id", &|ir| ir.org.goals[0].steward = "core!".into());
    invalid("agent id", &|ir| ir.org.agents[0].id = "builder\"".into());
    invalid("agent id", &|ir| {
        ir.org.goals[0].mandates[0].principal.id = "a".repeat(41)
    });
    invalid("handle", &|ir| ir.org.agents[0].operator = "@mina".into());
    invalid("handle", &|ir| {
        ir.org.goals[0].mandates[1].principal.id = "j".into()
    });
    invalid("capability", &|ir| {
        ir.org.goals[0].mandates[1].capabilities.push("fly".into())
    });
    invalid("metric name", &|ir| {
        ir.org.goals[0].mandates[0].capabilities[2] = "report_metric:Revenue".into()
    });
    invalid("date", &|ir| {
        ir.org.goals[0].mandates[0].expires = Some("2027-02-30".into())
    });
    invalid("amount", &|ir| {
        ir.org.goals[0].mandates[0].per_request_micros = Some(MAX_MONEY_MICROS + 1)
    });
    invalid("amount", &|ir| {
        ir.org.goals[0].rules[0].subject = maru_core::ir::Subject::Spend {
            category: None,
            over_micros: Some(u64::MAX),
        }
    });
    invalid("rule id", &|ir| {
        ir.org.goals[0].rules[0].id = "other:r_866679bf".into()
    });
    invalid("rule id", &|ir| {
        ir.org.goals[0].rules[0].id = "editor:r_866679BF".into()
    });

    let mut ir = lumen.clone();
    ir.ir_version = 2;
    assert_eq!(
        compile(&ir).err(),
        Some(CompileError::UnsupportedIrVersion(2))
    );
    // Limits the checker allows compile.
    let mut ir = lumen.clone();
    ir.org.goals[0].mandates[0].per_request_micros = Some(MAX_MONEY_MICROS);
    ir.org.goals[0].mandates[0].principal.id = "a".repeat(40);
    ir.org.agents[0].id = "a".repeat(40);
    assert!(compile(&ir).is_ok());
}

// See OQ-13.
#[test]
fn l06_colliding_policy_ids_do_not_compile() {
    // A goal `self` has rules `self:r_<hex>`; a person whose handle is `r_<hex>` has the
    // policy `self:r_<hex>`.
    let rule = "rule spend requires approve(core, 1)";
    let colliding = rule_id("self", rule);
    let handle = colliding.strip_prefix("self:").unwrap();
    let src = format!(
        "org \"T\" {{\n  amend: approve(core, 1)\n\n  circle core {{\n    seats: 1\n    holders: @mina\n  }}\n\n  goal self \"S\" {{\n    steward: core\n\n    mandate @{handle} {{\n      can: claim_tasks\n    }}\n\n    {rule}\n  }}\n}}\n"
    );
    let ir = ir_ok(&src);
    assert_eq!(ir.org.goals[0].rules[0].id, colliding);
    assert_eq!(
        compile(&ir).err(),
        Some(CompileError::DuplicatePolicyId(colliding))
    );
}

#[test]
fn l06_json_shapes() {
    assert_eq!(
        serde_json::to_value(Decision::Allow).unwrap(),
        json!({"decision": "allow"})
    );
    assert_eq!(
        serde_json::to_value(Decision::Deny {
            reason: DenyReason::PerRequestExceeded
        })
        .unwrap(),
        json!({"decision": "deny", "reason": "per_request_exceeded"})
    );
    assert_eq!(
        serde_json::to_value(requires(&["editor:r_1"])).unwrap(),
        json!({"decision": "requires_approval", "rule_ids": ["editor:r_1"]})
    );
    let reasons: Vec<Value> = [
        DenyReason::NoMandate,
        DenyReason::CategoryNotPermitted,
        DenyReason::PerRequestExceeded,
        DenyReason::MandateExpired,
        DenyReason::CapabilityMissing,
        DenyReason::NotSteward,
        DenyReason::NotOperator,
        DenyReason::Forbidden,
    ]
    .iter()
    .map(|r| serde_json::to_value(r).unwrap())
    .collect();
    assert_eq!(
        reasons,
        [
            "no_mandate",
            "category_not_permitted",
            "per_request_exceeded",
            "mandate_expired",
            "capability_missing",
            "not_steward",
            "not_operator",
            "forbidden"
        ]
    );
    let actions: Vec<Value> = Action::ALL
        .iter()
        .map(|a| serde_json::to_value(a).unwrap())
        .collect();
    assert_eq!(
        actions,
        [
            "spend",
            "claim_task",
            "create_task",
            "post_evidence",
            "post_goal_evidence",
            "report_metric",
            "review_task",
            "cancel_task",
            "pause_goal",
            "resume_goal",
            "request_close",
            "manage_secrets",
            "issue_token",
            "start_session"
        ]
    );

    let request = json!({
        "principal": {"kind": "agent", "id": "builder"},
        "action": "spend",
        "resource": {"kind": "goal", "id": "editor"},
        "context": {"category": "llm", "amount_micros": 10_000_000, "approved_rules": [],
                    "metric": "", "goal": "", "now_epoch": NOW},
        "effective_holders": {"core": ["mina", "jo"]}
    });
    let parsed: DecisionRequest = serde_json::from_value(request.clone()).unwrap();
    assert_eq!(parsed, spend(agent("builder"), "llm", usd(10)));
    assert_eq!(serde_json::to_value(&parsed).unwrap(), request);
    // Every field is required, and nothing else is accepted.
    let mut missing = request.clone();
    missing["context"].as_object_mut().unwrap().remove("metric");
    assert!(serde_json::from_value::<DecisionRequest>(missing).is_err());
    let mut extra = request.clone();
    extra["context"]["task"] = json!("t");
    assert!(serde_json::from_value::<DecisionRequest>(extra).is_err());
    let mut unknown = request.clone();
    unknown["action"] = json!("Spend");
    assert!(serde_json::from_value::<DecisionRequest>(unknown).is_err());
    let mut negative = request;
    negative["context"]["amount_micros"] = json!(-1);
    assert!(serde_json::from_value::<DecisionRequest>(negative).is_err());
}

#[test]
fn l06_schema_declares_the_spec_model() {
    assert_eq!(
        CEDAR_SCHEMA,
        std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/schema/openmaru.cedarschema"
        ))
        .unwrap()
    );
    let schema = schema();
    let mut types: Vec<String> = schema.entity_types().map(|t| t.to_string()).collect();
    types.sort();
    assert_eq!(types, ["Agent", "Circle", "Goal", "Org", "Person"]);
    let mut actions: Vec<String> = schema.actions().map(|a| a.to_string()).collect();
    actions.sort();
    let mut expected: Vec<String> = Action::ALL
        .iter()
        .map(|a| format!("Action::\"{}\"", a.cedar_name()))
        .collect();
    expected.sort();
    assert_eq!(actions, expected);
}
