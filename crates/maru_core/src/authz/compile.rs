//! IR → Cedar policies (SPEC-04 §2.1).
//!
//! Policies are generated as a small model ([`Generated`]) and rendered to Cedar text.
//! Every string that comes from the IR (ids, handles, metric names, rule ids) reaches the
//! text through Cedar's own string escaping ([`lit`]); only fixed keywords, type names and
//! numbers are written directly. [`compile`] additionally requires each id to be one the
//! language allows, parses every policy under its id and validates the set against
//! [`CEDAR_SCHEMA`] in strict mode.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use cedar_policy::{Expression, Policy, PolicyId, PolicySet, Schema, ValidationMode, Validator};
use chrono::NaiveDate;
use thiserror::Error;

use super::explain::IrIndex;
use super::{Action, CEDAR_SCHEMA, ResourceKind};
use crate::ast::MAX_MONEY_MICROS;
use crate::ir::{IR_VERSION, Ir, Mandate, PrincipalKind, Rule, Runtime, Subject};

/// Why an IR does not compile. The checker never produces such an IR; these guard IRs
/// built or edited elsewhere.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CompileError {
    /// `ir_version` is not [`IR_VERSION`](crate::ir::IR_VERSION).
    #[error("unsupported IR version {0}")]
    UnsupportedIrVersion(u32),
    /// An id, handle, metric name, rule id, date or amount is not one the language allows.
    #[error("invalid {what} `{value}` in the IR")]
    InvalidIr {
        /// What the value is (`"goal id"`, `"handle"`, …).
        what: &'static str,
        /// The value.
        value: String,
    },
    /// Two generated policies would have the same id. Only an IR the checker never
    /// emits (such as two goals with one id) has them; see OQ-13 and OQ-15.
    #[error("two policies would have the id `{0}`")]
    DuplicatePolicyId(String),
    /// A generated policy does not parse (a bug).
    #[error("generated policy `{id}` does not parse: {message}")]
    Policy {
        /// The policy id.
        id: String,
        /// Cedar's message.
        message: String,
    },
    /// The generated policies do not validate against the schema in strict mode (a bug).
    #[error("generated policies do not validate against the Cedar schema: {0}")]
    Validation(String),
    /// The bundled Cedar schema does not parse (a bug).
    #[error("the Cedar schema does not parse: {0}")]
    Schema(String),
}

/// A compiled policy set plus the IR index `decide` explains denials with. Built once per
/// spec version; `Send + Sync`, so one value can serve concurrent requests.
#[derive(Debug, Clone)]
pub struct CompiledPolicy {
    /// Policy ids in text order.
    ids: Vec<String>,
    /// Every policy.
    set: PolicySet,
    /// The policies of each resource. Every generated policy names one resource
    /// (`resource == …`), so only these can apply to a request about it.
    by_resource: HashMap<(ResourceKind, String), PolicySet>,
    /// For a resource no policy names.
    empty: PolicySet,
    /// Policy id → `@approval` rule id.
    approvals: HashMap<String, String>,
    /// What the explanation pass needs to know about the IR.
    pub(super) index: IrIndex,
}

impl CompiledPolicy {
    /// Policy ids, in the order of [`cedar_text`].
    pub fn policy_ids(&self) -> Vec<&str> {
        self.ids.iter().map(String::as_str).collect()
    }

    /// The whole Cedar policy set.
    pub fn policy_set(&self) -> &PolicySet {
        &self.set
    }

    /// The policies that can apply to `resource`.
    pub(super) fn policies_for(&self, kind: ResourceKind, id: &str) -> &PolicySet {
        self.by_resource
            .get(&(kind, id.to_string()))
            .unwrap_or(&self.empty)
    }

    /// The rule id of an `@approval` forbid, by policy id.
    pub(super) fn approval_rule(&self, policy_id: &str) -> Option<&str> {
        self.approvals.get(policy_id).map(String::as_str)
    }
}

/// The schema, parsed once.
static SCHEMA: LazyLock<Result<Schema, String>> = LazyLock::new(|| {
    Schema::from_cedarschema_str(CEDAR_SCHEMA)
        .map(|(schema, _warnings)| schema)
        .map_err(|e| e.to_string())
});

/// Compiles `ir` into a policy set validated against [`CEDAR_SCHEMA`](super::CEDAR_SCHEMA)
/// in strict mode.
///
/// # Errors
///
/// [`CompileError`] when the IR holds values the language does not allow, or two policies
/// would share an id.
pub fn compile(ir: &Ir) -> Result<CompiledPolicy, CompileError> {
    if ir.ir_version != IR_VERSION {
        return Err(CompileError::UnsupportedIrVersion(ir.ir_version));
    }
    validate(ir)?;
    let schema = SCHEMA
        .as_ref()
        .map_err(|e| CompileError::Schema(e.clone()))?;

    let generated = generate(ir);
    let mut ids = Vec::with_capacity(generated.len());
    let mut seen = HashSet::with_capacity(generated.len());
    let mut set = PolicySet::new();
    let mut by_resource: HashMap<(ResourceKind, String), PolicySet> = HashMap::new();
    let mut approvals = HashMap::new();
    for g in &generated {
        if !seen.insert(g.id.as_str()) {
            return Err(CompileError::DuplicatePolicyId(g.id.clone()));
        }
        let policy_error = |message: String| CompileError::Policy {
            id: g.id.clone(),
            message,
        };
        let policy = Policy::parse(Some(PolicyId::new(&g.id)), g.text())
            .map_err(|e| policy_error(e.to_string()))?;
        if let Some(rule) = policy.annotation("approval") {
            approvals.insert(g.id.clone(), rule.to_string());
        }
        set.add(policy.clone())
            .map_err(|e| policy_error(e.to_string()))?;
        by_resource
            .entry((g.resource.0, g.resource.1.clone()))
            .or_default()
            .add(policy)
            .map_err(|e| policy_error(e.to_string()))?;
        ids.push(g.id.clone());
    }

    let result = Validator::new(schema.clone()).validate(&set, ValidationMode::Strict);
    if !result.validation_passed() {
        return Err(CompileError::Validation(result.to_string()));
    }
    Ok(CompiledPolicy {
        ids,
        set,
        by_resource,
        empty: PolicySet::new(),
        approvals,
        index: IrIndex::new(ir),
    })
}

/// The Cedar policies for `ir` as text, for snapshots and the "Source → policy" view:
/// policies separated by a blank line, in the order of [`CompiledPolicy::policy_ids`].
///
/// It renders any IR, including ones [`compile`] rejects: strings are escaped, amounts
/// above `i64::MAX` are written as `i64::MAX`, and an expiry date that is not a date
/// becomes `0` (expired).
pub fn cedar_text(ir: &Ir) -> String {
    generate(ir)
        .iter()
        .map(Generated::text)
        .collect::<Vec<_>>()
        .join("\n")
}

// ---- the policy model ----

/// The Cedar entity types a policy names.
#[derive(Debug, Clone, Copy)]
enum EntityType {
    Person,
    Agent,
    Circle,
    Goal,
}

impl EntityType {
    const fn name(self) -> &'static str {
        match self {
            EntityType::Person => "Person",
            EntityType::Agent => "Agent",
            EntityType::Circle => "Circle",
            EntityType::Goal => "Goal",
        }
    }
}

impl From<PrincipalKind> for EntityType {
    fn from(kind: PrincipalKind) -> EntityType {
        match kind {
            PrincipalKind::Agent => EntityType::Agent,
            PrincipalKind::Person => EntityType::Person,
        }
    }
}

impl From<ResourceKind> for EntityType {
    fn from(kind: ResourceKind) -> EntityType {
        match kind {
            ResourceKind::Goal => EntityType::Goal,
            ResourceKind::Agent => EntityType::Agent,
            ResourceKind::Person => EntityType::Person,
        }
    }
}

/// A Cedar string literal for `s`, escaped by Cedar.
fn lit(s: &str) -> String {
    Expression::new_string(s.to_string()).to_string()
}

/// `Type::"id"`, the id escaped by Cedar.
fn uid(ty: EntityType, id: &str) -> String {
    format!("{}::{}", ty.name(), lit(id))
}

/// `Action::"Name"`.
fn action_uid(action: Action) -> String {
    format!("Action::\"{}\"", action.cedar_name())
}

/// A money amount as a Cedar `Long` (amounts above `i64::MAX` saturate).
fn long(micros: u64) -> i64 {
    i64::try_from(micros).unwrap_or(i64::MAX)
}

/// `00:00:00Z` on `date` (`YYYY-MM-DD`), in seconds since the epoch.
pub(super) fn date_epoch(date: &str) -> Option<i64> {
    let b = date.as_bytes();
    let shape = b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter()
            .enumerate()
            .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit());
    if !shape {
        return None;
    }
    NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .map(|t| t.and_utc().timestamp())
}

/// The steward powers (SPEC-04 §2.1).
const STEWARD_ACTIONS: [Action; 11] = [
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

/// The actions a capability grants (`report_metric:<name>` is handled separately).
pub(super) fn capability_actions(capability: &str) -> &'static [Action] {
    match capability {
        "claim_tasks" => &[Action::ClaimTask],
        "create_tasks" => &[Action::CreateTask],
        "post_evidence" => &[Action::PostEvidence, Action::PostGoalEvidence],
        _ => &[],
    }
}

/// The metric a `report_metric:<name>` capability names.
pub(super) fn capability_metric(capability: &str) -> Option<&str> {
    capability.strip_prefix("report_metric:")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Effect {
    Permit,
    Forbid,
}

/// `principal`, `principal == …` or `principal in …`.
#[derive(Debug, Clone)]
enum PrincipalScope {
    Any,
    Is(EntityType, String),
    In(EntityType, String),
}

/// One generated policy.
#[derive(Debug, Clone)]
struct Generated {
    id: String,
    /// Also annotated `@approval(<id>)`.
    approval: bool,
    effect: Effect,
    principal: PrincipalScope,
    actions: Vec<Action>,
    resource: (ResourceKind, String),
    /// Conditions joined with `&&`.
    when: Vec<String>,
    unless: Option<String>,
}

impl Generated {
    fn permit(
        id: String,
        principal: PrincipalScope,
        actions: Vec<Action>,
        resource: (ResourceKind, String),
        when: Vec<String>,
    ) -> Generated {
        Generated {
            id,
            approval: false,
            effect: Effect::Permit,
            principal,
            actions,
            resource,
            when,
            unless: None,
        }
    }

    /// The policy in the layout of SPEC-04 §2.1: the scope on one line for a single
    /// action, otherwise one line per scope element with the action list four to a line.
    fn text(&self) -> String {
        let id = lit(&self.id);
        let mut out = format!("@id({id})");
        if self.approval {
            out.push_str(&format!(" @approval({id})"));
        }
        out.push('\n');
        let head = match self.effect {
            Effect::Permit => "permit(",
            Effect::Forbid => "forbid(",
        };
        let principal = match &self.principal {
            PrincipalScope::Any => "principal".to_string(),
            PrincipalScope::Is(ty, id) => format!("principal == {}", uid(*ty, id)),
            PrincipalScope::In(ty, id) => format!("principal in {}", uid(*ty, id)),
        };
        let resource = format!(
            "resource == {}",
            uid(self.resource.0.into(), &self.resource.1)
        );
        out.push_str(head);
        if let [action] = self.actions.as_slice() {
            out.push_str(&format!(
                "{principal}, action == {}, {resource})",
                action_uid(*action)
            ));
        } else {
            let indent = " ".repeat(head.len());
            let list_indent = format!("{indent}{}", " ".repeat("action in [".len()));
            let rows: Vec<String> = self
                .actions
                .chunks(4)
                .map(|row| {
                    row.iter()
                        .map(|a| action_uid(*a))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .collect();
            out.push_str(&format!(
                "{principal},\n{indent}action in [{}],\n{indent}{resource})",
                rows.join(&format!(",\n{list_indent}"))
            ));
        }
        if !self.when.is_empty() {
            out.push_str(&format!("\nwhen {{ {} }}", self.when.join(" && ")));
        }
        if let Some(unless) = &self.unless {
            out.push_str(&format!("\nunless {{ {unless} }}"));
        }
        out.push_str(";\n");
        out
    }
}

/// The `now_epoch` guard for a mandate's expiry, if it has one.
fn expiry_guard(mandate: &Mandate) -> Option<String> {
    mandate.expires.as_deref().map(|date| {
        format!(
            "context.now_epoch < {}",
            date_epoch(date).unwrap_or_default()
        )
    })
}

/// Every policy for `ir`, in text order: per goal its steward powers, steward sessions,
/// mandates (capabilities, metrics, spend lines) and approval rules; then one operator
/// policy per agent and one `self-token` policy per person holding a mandate.
fn generate(ir: &Ir) -> Vec<Generated> {
    let mut out = Vec::new();
    let hosted: HashSet<&str> = ir
        .org
        .agents
        .iter()
        .filter(|a| a.runtime == Runtime::Hosted)
        .map(|a| a.id.as_str())
        .collect();
    let mut people: Vec<&str> = Vec::new();

    for goal in &ir.org.goals {
        let resource = (ResourceKind::Goal, goal.id.clone());
        out.push(Generated::permit(
            format!("steward:{}", goal.id),
            PrincipalScope::In(EntityType::Circle, goal.steward.clone()),
            STEWARD_ACTIONS.to_vec(),
            resource.clone(),
            vec![],
        ));
        for mandate in &goal.mandates {
            let p = &mandate.principal;
            if p.kind == PrincipalKind::Agent && hosted.contains(p.id.as_str()) {
                out.push(Generated::permit(
                    format!("steward-session:{}:{}", goal.id, p.id),
                    PrincipalScope::In(EntityType::Circle, goal.steward.clone()),
                    vec![Action::StartSession],
                    (ResourceKind::Agent, p.id.clone()),
                    vec![format!("context.goal == {}", lit(&goal.id))],
                ));
            }
        }
        for mandate in &goal.mandates {
            mandate_policies(&goal.id, mandate, &mut out);
            if mandate.principal.kind == PrincipalKind::Person
                && !people.contains(&mandate.principal.id.as_str())
            {
                people.push(&mandate.principal.id);
            }
        }
        for rule in &goal.rules {
            if let Some(policy) = rule_policy(&goal.id, rule) {
                out.push(policy);
            }
        }
    }

    for agent in &ir.org.agents {
        out.push(Generated::permit(
            format!("operator:{}", agent.id),
            PrincipalScope::Is(EntityType::Person, agent.operator.clone()),
            vec![Action::IssueToken, Action::StartSession],
            (ResourceKind::Agent, agent.id.clone()),
            vec![],
        ));
    }
    for person in people {
        out.push(Generated::permit(
            format!("self-token:{person}"),
            PrincipalScope::Is(EntityType::Person, person.to_string()),
            vec![Action::IssueToken],
            (ResourceKind::Person, person.to_string()),
            vec![],
        ));
    }
    out
}

/// A mandate's capability, metric and spend policies.
fn mandate_policies(goal: &str, mandate: &Mandate, out: &mut Vec<Generated>) {
    let p = &mandate.principal;
    let kind = match p.kind {
        PrincipalKind::Agent => "agent",
        PrincipalKind::Person => "person",
    };
    let prefix = format!("mandate:{goal}:{kind}:{}", p.id);
    let principal = PrincipalScope::Is(p.kind.into(), p.id.clone());
    let resource = (ResourceKind::Goal, goal.to_string());
    let expiry = expiry_guard(mandate);

    let mut actions: Vec<Action> = Vec::new();
    let mut metrics: Vec<&str> = Vec::new();
    for capability in &mandate.capabilities {
        for action in capability_actions(capability) {
            if !actions.contains(action) {
                actions.push(*action);
            }
        }
        if let Some(metric) = capability_metric(capability) {
            if !metrics.contains(&metric) {
                metrics.push(metric);
            }
        }
    }
    if !actions.is_empty() {
        out.push(Generated::permit(
            format!("{prefix}:caps"),
            principal.clone(),
            actions,
            resource.clone(),
            expiry.iter().cloned().collect(),
        ));
    }
    if !metrics.is_empty() {
        let names: Vec<String> = metrics.iter().map(|m| lit(m)).collect();
        let mut when = vec![format!("[{}].contains(context.metric)", names.join(", "))];
        when.extend(expiry.iter().cloned());
        out.push(Generated::permit(
            format!("{prefix}:metrics"),
            principal.clone(),
            vec![Action::ReportMetric],
            resource.clone(),
            when,
        ));
    }
    for line in &mandate.spend {
        let category = line.category.as_str();
        let mut when = vec![format!("context.category == {}", lit(category))];
        if let Some(cap) = mandate.per_request_micros {
            when.push(format!("context.amount_micros <= {}", long(cap)));
        }
        when.extend(expiry.iter().cloned());
        out.push(Generated::permit(
            format!("{prefix}:spend:{category}"),
            principal.clone(),
            vec![Action::Spend],
            resource.clone(),
            when,
        ));
    }
}

/// The annotated forbid for a spend rule; `rule close` compiles to nothing.
fn rule_policy(goal: &str, rule: &Rule) -> Option<Generated> {
    let Subject::Spend {
        category,
        over_micros,
    } = &rule.subject
    else {
        return None;
    };
    let mut when = Vec::new();
    if let Some(category) = category {
        when.push(format!("context.category == {}", lit(category.as_str())));
    }
    if let Some(over) = over_micros {
        when.push(format!("context.amount_micros > {}", long(*over)));
    }
    Some(Generated {
        id: rule.id.clone(),
        approval: true,
        effect: Effect::Forbid,
        principal: PrincipalScope::Any,
        actions: vec![Action::Spend],
        resource: (ResourceKind::Goal, goal.to_string()),
        when,
        unless: Some(format!(
            "context.approved_rules.contains({})",
            lit(&rule.id)
        )),
    })
}

// ---- IR validation ----

/// `IDENT` (SPEC-01 §2): `[a-z][a-z0-9_]*`, at most 40 characters.
fn is_ident(s: &str) -> bool {
    let mut chars = s.chars();
    s.len() <= 40
        && chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// `HANDLE` without `@` (SPEC-01 §2): `[a-z0-9][a-z0-9_-]{1,29}`.
fn is_handle(s: &str) -> bool {
    (2..=30).contains(&s.len())
        && s.chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// `<goal>:r_<8 lowercase hex>` (SPEC-01 §4.6).
fn is_rule_id(goal: &str, id: &str) -> bool {
    id.strip_prefix(goal)
        .and_then(|rest| rest.strip_prefix(":r_"))
        .is_some_and(|hash| {
            hash.len() == 8 && hash.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
        })
}

fn require(ok: bool, what: &'static str, value: &str) -> Result<(), CompileError> {
    if ok {
        Ok(())
    } else {
        Err(CompileError::InvalidIr {
            what,
            value: value.to_string(),
        })
    }
}

fn require_amount(micros: u64) -> Result<(), CompileError> {
    require(micros <= MAX_MONEY_MICROS, "amount", &micros.to_string())
}

/// Checks every value the policies print.
fn validate(ir: &Ir) -> Result<(), CompileError> {
    for agent in &ir.org.agents {
        require(is_ident(&agent.id), "agent id", &agent.id)?;
        require(is_handle(&agent.operator), "handle", &agent.operator)?;
    }
    for goal in &ir.org.goals {
        require(is_ident(&goal.id), "goal id", &goal.id)?;
        require(is_ident(&goal.steward), "circle id", &goal.steward)?;
        for mandate in &goal.mandates {
            let p = &mandate.principal;
            match p.kind {
                PrincipalKind::Agent => require(is_ident(&p.id), "agent id", &p.id)?,
                PrincipalKind::Person => require(is_handle(&p.id), "handle", &p.id)?,
            }
            for capability in &mandate.capabilities {
                match capability_metric(capability) {
                    Some(metric) => require(is_ident(metric), "metric name", metric)?,
                    None => require(
                        !capability_actions(capability).is_empty(),
                        "capability",
                        capability,
                    )?,
                }
            }
            if let Some(date) = &mandate.expires {
                require(date_epoch(date).is_some(), "date", date)?;
            }
            if let Some(cap) = mandate.per_request_micros {
                require_amount(cap)?;
            }
        }
        for rule in &goal.rules {
            require(is_rule_id(&goal.id, &rule.id), "rule id", &rule.id)?;
            if let Subject::Spend {
                over_micros: Some(over),
                ..
            } = rule.subject
            {
                require_amount(over)?;
            }
        }
    }
    Ok(())
}
