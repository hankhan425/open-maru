//! The explanation pass: why a request is denied (SPEC-04 §3, step 4). It reads the IR,
//! not the policies, so its answer does not depend on `approved_rules`.

use std::collections::{HashMap, HashSet};

use super::compile::{capability_actions, capability_metric, date_epoch};
use super::{Action, DecisionRequest, DenyReason, ResourceKind};
use crate::ir::{Ir, Mandate, PrincipalKind};

/// What the explanation pass knows about the IR. A repeated id resolves to its first
/// declaration, as in the checker.
#[derive(Debug, Clone, Default)]
pub(super) struct IrIndex {
    goals: HashMap<String, GoalFacts>,
    agents: HashSet<String>,
}

#[derive(Debug, Clone)]
struct GoalFacts {
    steward: String,
    mandates: HashMap<(PrincipalKind, String), MandateFacts>,
}

#[derive(Debug, Clone)]
struct MandateFacts {
    categories: Vec<&'static str>,
    per_request_micros: Option<u64>,
    /// `None` without an expiry; an unparseable date counts as expired from the epoch.
    expires_epoch: Option<i64>,
    actions: HashSet<Action>,
    metrics: HashSet<String>,
}

impl MandateFacts {
    fn new(mandate: &Mandate) -> MandateFacts {
        let caps = &mandate.capabilities;
        MandateFacts {
            categories: mandate.spend.iter().map(|s| s.category.as_str()).collect(),
            per_request_micros: mandate.per_request_micros,
            expires_epoch: mandate
                .expires
                .as_deref()
                .map(|d| date_epoch(d).unwrap_or_default()),
            actions: caps
                .iter()
                .flat_map(|c| capability_actions(c))
                .copied()
                .collect(),
            metrics: caps
                .iter()
                .filter_map(|c| capability_metric(c))
                .map(str::to_string)
                .collect(),
        }
    }

    fn expired(&self, now_epoch: i64) -> bool {
        self.expires_epoch.is_some_and(|at| now_epoch >= at)
    }

    fn grants(&self, action: Action, metric: &str) -> bool {
        match action {
            Action::ReportMetric => self.metrics.contains(metric),
            _ => self.actions.contains(&action),
        }
    }
}

impl IrIndex {
    pub(super) fn new(ir: &Ir) -> IrIndex {
        let mut index = IrIndex::default();
        for agent in &ir.org.agents {
            index.agents.insert(agent.id.clone());
        }
        for goal in &ir.org.goals {
            let facts = index
                .goals
                .entry(goal.id.clone())
                .or_insert_with(|| GoalFacts {
                    steward: goal.steward.clone(),
                    mandates: HashMap::new(),
                });
            for mandate in &goal.mandates {
                let p = &mandate.principal;
                facts
                    .mandates
                    .entry((p.kind, p.id.clone()))
                    .or_insert_with(|| MandateFacts::new(mandate));
            }
        }
        index
    }
}

/// The reason for a denial, first match wins (SPEC-04 §3, step 4). A resource the spec
/// does not have, or of the wrong kind for the action, is `Forbidden` (OQ-14).
pub(super) fn explain(index: &IrIndex, req: &DecisionRequest) -> DenyReason {
    let resource = &req.resource;
    match req.action {
        Action::IssueToken => match resource.kind {
            ResourceKind::Agent if index.agents.contains(&resource.id) => DenyReason::NotOperator,
            ResourceKind::Person => DenyReason::NotOperator,
            _ => DenyReason::Forbidden,
        },
        Action::StartSession => match resource.kind {
            ResourceKind::Agent if index.agents.contains(&resource.id) => DenyReason::NotOperator,
            _ => DenyReason::Forbidden,
        },
        action => {
            let goal = match resource.kind {
                ResourceKind::Goal => index.goals.get(&resource.id),
                ResourceKind::Agent | ResourceKind::Person => None,
            };
            let Some(goal) = goal else {
                return DenyReason::Forbidden;
            };
            let principal = &req.principal;
            let mandate = goal.mandates.get(&(principal.kind, principal.id.clone()));
            let ctx = &req.context;
            if action == Action::Spend {
                let Some(m) = mandate else {
                    return DenyReason::NoMandate;
                };
                if !m.categories.contains(&ctx.category.as_str()) {
                    DenyReason::CategoryNotPermitted
                } else if m.expired(ctx.now_epoch) {
                    DenyReason::MandateExpired
                } else if m
                    .per_request_micros
                    .is_some_and(|cap| ctx.amount_micros > cap)
                {
                    DenyReason::PerRequestExceeded
                } else {
                    DenyReason::Forbidden
                }
            } else {
                let Some(m) = mandate else {
                    let holder = principal.kind == PrincipalKind::Person
                        && req
                            .effective_holders
                            .get(&goal.steward)
                            .is_some_and(|hs| hs.contains(&principal.id));
                    return if holder {
                        DenyReason::Forbidden
                    } else {
                        DenyReason::NotSteward
                    };
                };
                if !m.grants(action, &ctx.metric) {
                    DenyReason::CapabilityMissing
                } else if m.expired(ctx.now_epoch) {
                    DenyReason::MandateExpired
                } else {
                    DenyReason::Forbidden
                }
            }
        }
    }
}
