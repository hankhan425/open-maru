//! Limits analysis (SPEC-01 §6.1): the most a goal can spend in one calendar month
//! without any approval.

use crate::ir::{Category, Mandate, Outcome, Period, Rule, Subject};

/// How many periods of a kind can start in one calendar month: month 1, week 6, day 31.
pub const fn factor(period: Period) -> u64 {
    match period {
        Period::Month => 1,
        Period::Week => 6,
        Period::Day => 31,
    }
}

/// Whether some rule gates every spend of `category` with no amount threshold and
/// `else deny`, which excludes that category's spend lines from the analysis.
pub fn excluded(rules: &[Rule], category: Category) -> bool {
    rules.iter().any(|rule| {
        rule.otherwise == Outcome::Deny
            && matches!(
                rule.subject,
                Subject::Spend { category: c, over_micros: None } if c.is_none_or(|c| c == category)
            )
    })
}

/// The exact sum of `limit × factor(period)` over every spend line not [`excluded`]. It
/// can exceed the money maximum; the checker reports E318 then.
pub fn unapproved_monthly_max(mandates: &[Mandate], rules: &[Rule]) -> u128 {
    let [llm, compute, expense] =
        [Category::Llm, Category::Compute, Category::Expense].map(|c| excluded(rules, c));
    let skip = |category| match category {
        Category::Llm => llm,
        Category::Compute => compute,
        Category::Expense => expense,
    };
    mandates
        .iter()
        .flat_map(|m| &m.spend)
        .filter(|line| !skip(line.category))
        .map(|line| u128::from(line.limit_micros) * u128::from(factor(line.period)))
        .fold(0u128, u128::saturating_add)
}
