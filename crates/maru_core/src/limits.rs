//! Limits analysis (SPEC-01 §6.1): the most a goal can spend in one calendar month
//! without any approval.

use crate::ir::{Category, Mandate, Period, Rule};

/// How many periods of a kind can start in one calendar month: month 1, week 6, day 31.
pub const fn factor(_period: Period) -> u64 {
    panic!("L03: not implemented")
}

/// Whether some rule gates every spend of `category` with no amount threshold and
/// `else deny`, which excludes that category's spend lines from the analysis.
pub fn excluded(_rules: &[Rule], _category: Category) -> bool {
    unimplemented!("L03")
}

/// The exact sum of `limit × factor(period)` over every spend line not [`excluded`]. It
/// can exceed the money maximum; the checker reports E318 then.
pub fn unapproved_monthly_max(_mandates: &[Mandate], _rules: &[Rule]) -> u128 {
    unimplemented!("L03")
}
