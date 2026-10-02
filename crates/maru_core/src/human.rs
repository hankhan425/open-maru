//! Plain-English formatting helpers shared by the charter (SPEC-01 §8) and the semantic
//! diff (§9). The web app formats the same values the same way; the shared vectors in
//! `tests/vectors/human.json` pin every helper.
//!
//! Helpers return plain text (not Markdown-escaped) and never depend on the locale, the
//! time zone or any other environment.

use crate::ir::DurationUnit;

/// Money in micro-USD as dollars: `$12,000` for whole dollars, otherwise 2 to 6 decimals
/// with trailing zeros trimmed past 2 (`$12.50`, `$0.000125`, `$1,234.56789`).
pub fn money(_micros: u64) -> String {
    unimplemented!("L04")
}

/// A decimal string (`-`, digits, optional `.` and digits) with its integer part grouped
/// by thousands: `10000` → `10,000`, `-1500.5` → `-1,500.5`. The fraction is kept as
/// written. Anything else is returned unchanged.
pub fn number(_decimal: &str) -> String {
    unimplemented!("L04")
}

/// A duration as words, singular when the count is 1: `30 minutes`, `1 hour`, `2 weeks`.
pub fn duration(_value: u64, _unit: DurationUnit) -> String {
    unimplemented!("L04")
}

/// A `YYYY-MM-DD` date as `June 30, 2027`. A string that is not a valid date in that form
/// is returned unchanged.
pub fn date(_iso: &str) -> String {
    unimplemented!("L04")
}

/// An English list: `a`; `a and b`; `a, b, and c`. Empty when `items` is.
pub fn list<S: AsRef<str>>(_items: &[S]) -> String {
    unimplemented!("L04")
}

/// A vote threshold as written: percents as `60%`; `1/2` `half`, `1/3` `one-third`, `2/3`
/// `two-thirds`, `3/4` `three-quarters`; other fractions as `a/b`, unreduced.
pub fn threshold(_num: u32, _den: u32, _is_percent: bool) -> String {
    unimplemented!("L04")
}
