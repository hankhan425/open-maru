//! L06 properties: `decide` over random requests (T19, T20), and spec strings in the
//! generated Cedar text (acceptance: no injection).
#![cfg(feature = "authz")]
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use std::collections::{BTreeMap, BTreeSet};
use std::str::FromStr;
use std::sync::LazyLock;

use cedar_policy::PolicySet;
use maru_core::authz::{
    Action, CompileError, CompiledPolicy, Decision, DecisionRequest, DenyReason, RequestContext,
    ResourceRef, cedar_text, compile, decide,
};
use maru_core::ir::Ir;
use proptest::prelude::*;
use support::decide_cases::*;

static LUMEN_IR: LazyLock<Ir> = LazyLock::new(|| fixture_ir("lumen.maru"));
static LUMEN: LazyLock<CompiledPolicy> = LazyLock::new(|| compile(&LUMEN_IR).unwrap());

/// Lumen's rule ids, including the close rule (which compiles to nothing).
fn lumen_rule_ids() -> Vec<String> {
    LUMEN_IR.org.goals[0]
        .rules
        .iter()
        .map(|r| r.id.clone())
        .collect()
}

/// Rule ids an `approved_rules` set may hold: lumen's, and some that are not.
fn approved_rules() -> impl Strategy<Value = Vec<String>> {
    let mut pool = lumen_rule_ids();
    pool.extend(["editor:r_00000000", "junk", ""].map(String::from));
    prop::sample::subsequence(pool.clone(), 0..=pool.len())
}

fn request() -> impl Strategy<Value = DecisionRequest> {
    let principal = prop::sample::select(vec![
        agent("builder"),
        agent("ghost"),
        agent("jo"),
        person("mina"),
        person("jo"),
        person("sam"),
        person("builder"),
    ]);
    let action = prop::sample::select(Action::ALL.to_vec());
    let resource: Vec<ResourceRef> = vec![
        goal("editor"),
        goal("nope"),
        agent_resource("builder"),
        agent_resource("ghost"),
        person_resource("jo"),
        person_resource("mina"),
    ];
    let resource = prop::sample::select(resource);
    let category = prop::sample::select(vec!["llm", "compute", "expense", "", "travel"]);
    let amount = prop_oneof![
        4 => prop::sample::select(vec![
            0,
            1,
            usd(10),
            usd(25),
            usd(25) + 1,
            usd(100),
            usd(500),
            usd(500) + 1,
            usd(600),
            i64::MAX as u64,
            u64::MAX,
        ]),
        4 => 0..usd(2_000),
        1 => any::<u64>(),
    ];
    let metric = prop::sample::select(vec!["", "weekly_active_users", "revenue"]);
    let session_goal = prop::sample::select(vec!["", "editor", "other"]);
    let now = prop_oneof![
        4 => prop::sample::select(vec![
            NOW,
            JAN_2027 - 1,
            JAN_2027,
            JAN_2027 + 1,
            0,
            i64::MIN,
            i64::MAX,
        ]),
        1 => any::<i64>(),
    ];
    let people = vec!["mina", "jo", "sam"];
    let holders = (
        prop::sample::subsequence(people.clone(), 0..=3),
        prop::sample::subsequence(people, 0..=3),
    )
        .prop_map(|(core, ops)| {
            let mut map = BTreeMap::new();
            map.insert(
                "core".to_string(),
                core.into_iter().map(String::from).collect(),
            );
            map.insert(
                "ops".to_string(),
                ops.into_iter().map(String::from).collect(),
            );
            map
        });
    (
        (principal, action, resource),
        (
            category,
            amount,
            approved_rules(),
            metric,
            session_goal,
            now,
        ),
        holders,
    )
        .prop_map(
            |(
                (principal, action, resource),
                (category, amount_micros, approved_rules, metric, goal, now_epoch),
                effective_holders,
            )| DecisionRequest {
                principal,
                action,
                resource,
                context: RequestContext {
                    category: category.to_string(),
                    amount_micros,
                    approved_rules,
                    metric: metric.to_string(),
                    goal: goal.to_string(),
                    now_epoch,
                },
                effective_holders,
            },
        )
}

/// `rules` added to the request's approved rules.
fn with_approved(req: &DecisionRequest, rules: &[String]) -> DecisionRequest {
    let mut req = req.clone();
    let mut set: BTreeSet<String> = req.context.approved_rules.iter().cloned().collect();
    set.extend(rules.iter().cloned());
    req.context.approved_rules = set.into_iter().collect();
    req
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    // L06-T19
    #[test]
    fn l06_t19_approving_the_returned_rules_never_requires_them_again(req in request()) {
        let decision = decide(&LUMEN, &req);
        if let Decision::RequiresApproval { rule_ids } = decision {
            let known = lumen_rule_ids();
            prop_assert!(!rule_ids.is_empty());
            prop_assert!(rule_ids.windows(2).all(|w| w[0] < w[1]), "sorted: {:?}", rule_ids);
            prop_assert!(rule_ids.iter().all(|r| known.contains(r)), "{:?}", rule_ids);
            prop_assert!(
                rule_ids.iter().all(|r| !req.context.approved_rules.contains(r)),
                "already approved: {:?}", rule_ids
            );
            let again = decide(&LUMEN, &with_approved(&req, &rule_ids));
            prop_assert_ne!(&again, &Decision::RequiresApproval { rule_ids: rule_ids.clone() });
            prop_assert_eq!(again, Decision::Allow);
        }
    }

    // L06-T20
    #[test]
    fn l06_t20_approvals_cannot_bypass_mandates(req in request(), extra in approved_rules()) {
        let decision = decide(&LUMEN, &req);
        if let Decision::Deny { reason } = decision {
            if matches!(
                reason,
                DenyReason::PerRequestExceeded
                    | DenyReason::CategoryNotPermitted
                    | DenyReason::NoMandate
                    | DenyReason::MandateExpired
            ) {
                for approved in [extra.clone(), lumen_rule_ids()] {
                    let mut other = req.clone();
                    other.context.approved_rules = approved;
                    prop_assert_eq!(decide(&LUMEN, &other), Decision::Deny { reason });
                }
            }
        }
    }
}

/// Strings that would break naive concatenation into Cedar text.
fn hostile() -> impl Strategy<Value = String> {
    prop_oneof![
        3 => prop::sample::select(vec![
            "\"",
            "\\",
            "\\\"",
            "x\"); permit(principal, action, resource); //",
            "\") when { true }; permit(principal, action, resource) when { \"",
            "a\nb",
            "*/",
            "'",
            "é",
            "🦀",
            "\u{0}",
            "\u{202e}",
            "\u{feff}",
            "",
        ])
        .prop_map(String::from),
        1 => any::<String>(),
    ]
}

/// Lumen with every id the policies print replaced.
#[derive(Debug, Clone)]
struct Renamed {
    goal: String,
    circle: String,
    agent: String,
    mina: String,
    jo: String,
    metric: String,
    over_500: String,
    expense: String,
}

fn renamed() -> impl Strategy<Value = Renamed> {
    (
        (hostile(), hostile(), hostile(), hostile()),
        (hostile(), hostile(), hostile(), hostile()),
    )
        .prop_map(
            |((goal, circle, agent, mina), (jo, metric, over_500, expense))| Renamed {
                goal,
                circle,
                agent,
                mina,
                jo,
                metric,
                over_500,
                expense,
            },
        )
}

/// `[a-z][a-z0-9_]{0,39}`.
fn is_ident(s: &str) -> bool {
    let mut chars = s.chars();
    s.len() <= 40
        && chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// `[a-z0-9][a-z0-9_-]{1,29}`.
fn is_handle(s: &str) -> bool {
    (2..=30).contains(&s.len())
        && s.chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

impl Renamed {
    /// Whether every name is one the language allows (then compile may succeed).
    fn all_valid(&self) -> bool {
        let rule = |id: &str| {
            id.strip_prefix(&format!("{}:r_", self.goal))
                .is_some_and(|h| {
                    h.len() == 8 && h.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
                })
        };
        is_ident(&self.goal)
            && is_ident(&self.circle)
            && is_ident(&self.agent)
            && is_ident(&self.metric)
            && is_handle(&self.mina)
            && is_handle(&self.jo)
            && rule(&self.over_500)
            && rule(&self.expense)
    }

    fn apply(&self, ir: &Ir) -> Ir {
        let mut ir = ir.clone();
        ir.org.agents[0].id = self.agent.clone();
        ir.org.agents[0].operator = self.mina.clone();
        let g = &mut ir.org.goals[0];
        g.id = self.goal.clone();
        g.steward = self.circle.clone();
        g.mandates[0].principal.id = self.agent.clone();
        g.mandates[0].capabilities[2] = format!("report_metric:{}", self.metric);
        g.mandates[1].principal.id = self.jo.clone();
        g.rules[0].id = self.over_500.clone();
        g.rules[1].id = self.expense.clone();
        ir
    }

    fn expected_ids(&self) -> Vec<String> {
        let Renamed {
            goal,
            agent,
            jo,
            over_500,
            expense,
            ..
        } = self;
        vec![
            format!("steward:{goal}"),
            format!("steward-session:{goal}:{agent}"),
            format!("mandate:{goal}:agent:{agent}:caps"),
            format!("mandate:{goal}:agent:{agent}:metrics"),
            format!("mandate:{goal}:agent:{agent}:spend:llm"),
            format!("mandate:{goal}:agent:{agent}:spend:compute"),
            format!("mandate:{goal}:person:{jo}:caps"),
            format!("mandate:{goal}:person:{jo}:spend:expense"),
            over_500.clone(),
            expense.clone(),
            format!("operator:{agent}"),
            format!("self:{jo}"),
        ]
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(500))]

    // Acceptance: ids and strings from the IR are escaped, so they cannot add, remove or
    // change policies, and compile rejects ids the language does not allow.
    #[test]
    fn l06_spec_strings_cannot_change_the_policy_structure(names in renamed()) {
        let ir = names.apply(&LUMEN_IR);
        let text = cedar_text(&ir);
        let set = PolicySet::from_str(&text);
        prop_assert!(set.is_ok(), "{:?}\n{}", set.err(), text);
        let set = set.unwrap();
        let ids: Vec<String> = set
            .policies()
            .map(|p| p.annotation("id").unwrap_or_default().to_string())
            .collect();
        let mut expected = names.expected_ids();
        let mut sorted = ids.clone();
        sorted.sort();
        expected.sort();
        prop_assert_eq!(sorted, expected);
        for policy in set.policies() {
            let id = policy.annotation("id").unwrap_or_default();
            let approval = policy.annotation("approval");
            if id == names.over_500 || id == names.expense {
                prop_assert_eq!(approval, Some(id));
            }
            if approval.is_some() {
                prop_assert!(id == names.over_500 || id == names.expense, "{}", id);
            }
        }
        if !names.all_valid() {
            let result = compile(&ir);
            prop_assert!(
                matches!(result, Err(CompileError::InvalidIr { .. })),
                "{:?}", result.err()
            );
        }
    }
}
