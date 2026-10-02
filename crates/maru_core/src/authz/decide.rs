//! `decide` (SPEC-04 §3).

use std::collections::{BTreeSet, HashSet};
use std::str::FromStr;
use std::sync::LazyLock;

use cedar_policy::{
    Authorizer, Context, Entities, Entity, EntityId, EntityTypeName, EntityUid, PolicyId,
    PolicySet, Request, RestrictedExpression,
};

use super::compile::CompiledPolicy;
use super::explain::explain;
use super::{Decision, DecisionRequest, DenyReason, ResourceKind};
use crate::ir::PrincipalKind;

static AUTHORIZER: LazyLock<Authorizer> = LazyLock::new(Authorizer::new);

/// Answers `req` under `policy` (SPEC-04 §3):
///
/// 1. Evaluate the policies of the request's resource, with `Person in [Circle]` from
///    `req.effective_holders`.
/// 2. `Allow` → [`Decision::Allow`].
/// 3. A `Deny` decided only by `@approval` forbids is evaluated again with their rule ids
///    approved; if that allows, the answer is [`Decision::RequiresApproval`] with those ids,
///    sorted.
/// 4. Otherwise [`Decision::Deny`] with the reason from the explanation pass over the IR.
///
/// Fails closed: a request Cedar cannot evaluate is denied as `Forbidden`.
pub fn decide(policy: &CompiledPolicy, req: &DecisionRequest) -> Decision {
    let deny = |reason| Decision::Deny { reason };
    let Some(cedar) = CedarRequest::new(req) else {
        return deny(DenyReason::Forbidden);
    };
    let policies = policy.policies_for(req.resource.kind, &req.resource.id);
    match cedar.evaluate(policies, &req.context.approved_rules) {
        Evaluation::Allow => Decision::Allow,
        Evaluation::Error => deny(DenyReason::Forbidden),
        Evaluation::Deny(determining) => {
            let rules: Option<BTreeSet<String>> = determining
                .iter()
                .map(|id| policy.approval_rule(id).map(str::to_string))
                .collect();
            if let Some(rules) = rules.filter(|r| !r.is_empty()) {
                let mut approved = req.context.approved_rules.clone();
                approved.extend(rules.iter().cloned());
                if cedar.evaluate(policies, &approved) == Evaluation::Allow {
                    return Decision::RequiresApproval {
                        rule_ids: rules.into_iter().collect(),
                    };
                }
            }
            deny(explain(&policy.index, req))
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Evaluation {
    Allow,
    /// Denied; the ids of the forbids that decided it (empty when no permit applied).
    Deny(Vec<String>),
    /// Some policy could not be evaluated.
    Error,
}

/// The parts of a Cedar request that do not depend on `approved_rules`.
struct CedarRequest<'a> {
    req: &'a DecisionRequest,
    principal: EntityUid,
    action: EntityUid,
    resource: EntityUid,
    entities: Entities,
}

/// The Cedar type names, parsed once.
struct TypeNames {
    person: EntityTypeName,
    agent: EntityTypeName,
    circle: EntityTypeName,
    goal: EntityTypeName,
    action: EntityTypeName,
}

static TYPES: LazyLock<Option<TypeNames>> = LazyLock::new(|| {
    let name = |n: &str| EntityTypeName::from_str(n).ok();
    Some(TypeNames {
        person: name("Person")?,
        agent: name("Agent")?,
        circle: name("Circle")?,
        goal: name("Goal")?,
        action: name("Action")?,
    })
});

impl<'a> CedarRequest<'a> {
    fn new(req: &'a DecisionRequest) -> Option<CedarRequest<'a>> {
        let types = TYPES.as_ref()?;
        let uid = |ty: &EntityTypeName, id: &str| {
            EntityUid::from_type_name_and_id(ty.clone(), EntityId::new(id))
        };
        let principal_type = match req.principal.kind {
            PrincipalKind::Person => &types.person,
            PrincipalKind::Agent => &types.agent,
        };
        let principal = uid(principal_type, &req.principal.id);
        let resource_type = match req.resource.kind {
            ResourceKind::Goal => &types.goal,
            ResourceKind::Agent => &types.agent,
            ResourceKind::Person => &types.person,
        };
        // Only a person's circles matter to the policies: `Person in [Circle]` from the
        // effective holders. Agents hold no circle.
        let entities = match req.principal.kind {
            PrincipalKind::Person => {
                let circles: HashSet<EntityUid> = req
                    .effective_holders
                    .iter()
                    .filter(|(_, holders)| holders.contains(&req.principal.id))
                    .map(|(circle, _)| uid(&types.circle, circle))
                    .collect();
                Entities::from_entities([Entity::new_no_attrs(principal.clone(), circles)], None)
                    .ok()?
            }
            PrincipalKind::Agent => Entities::empty(),
        };
        Some(CedarRequest {
            req,
            action: uid(&types.action, req.action.cedar_name()),
            resource: uid(resource_type, &req.resource.id),
            principal,
            entities,
        })
    }

    fn context(&self, approved_rules: &[String]) -> Option<Context> {
        let ctx = &self.req.context;
        let amount = i64::try_from(ctx.amount_micros).unwrap_or(i64::MAX);
        Context::from_pairs([
            (
                "category".to_string(),
                RestrictedExpression::new_string(ctx.category.clone()),
            ),
            (
                "amount_micros".to_string(),
                RestrictedExpression::new_long(amount),
            ),
            (
                "approved_rules".to_string(),
                RestrictedExpression::new_set(
                    approved_rules
                        .iter()
                        .map(|r| RestrictedExpression::new_string(r.clone())),
                ),
            ),
            (
                "metric".to_string(),
                RestrictedExpression::new_string(ctx.metric.clone()),
            ),
            (
                "goal".to_string(),
                RestrictedExpression::new_string(ctx.goal.clone()),
            ),
            (
                "now_epoch".to_string(),
                RestrictedExpression::new_long(ctx.now_epoch),
            ),
        ])
        .ok()
    }

    fn evaluate(&self, policies: &PolicySet, approved_rules: &[String]) -> Evaluation {
        let Some(context) = self.context(approved_rules) else {
            return Evaluation::Error;
        };
        let Ok(request) = Request::new(
            self.principal.clone(),
            self.action.clone(),
            self.resource.clone(),
            context,
            None,
        ) else {
            return Evaluation::Error;
        };
        let response = AUTHORIZER.is_authorized(&request, policies, &self.entities);
        if response.diagnostics().errors().next().is_some() {
            return Evaluation::Error;
        }
        match response.decision() {
            cedar_policy::Decision::Allow => Evaluation::Allow,
            cedar_policy::Decision::Deny => Evaluation::Deny(
                response
                    .diagnostics()
                    .reason()
                    .map(|id| <PolicyId as AsRef<str>>::as_ref(id).to_string())
                    .collect(),
            ),
        }
    }
}
