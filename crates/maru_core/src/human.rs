//! Plain-English formatting helpers shared by the charter (SPEC-01 §8) and the semantic
//! diff (§9). The web app formats the same values the same way; the shared vectors in
//! `tests/vectors/human.json` pin every helper.
//!
//! Helpers return plain text (not Markdown-escaped) and never depend on the locale, the
//! time zone or any other environment.

use chrono::NaiveDate;

use crate::ir::DurationUnit;

const MICROS_PER_USD: u64 = 1_000_000;

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

/// Money in micro-USD as dollars: `$12,000` for whole dollars, otherwise 2 to 6 decimals
/// with trailing zeros trimmed past 2 (`$12.50`, `$0.000125`, `$1,234.56789`).
pub fn money(micros: u64) -> String {
    let whole = group(&(micros / MICROS_PER_USD).to_string());
    let frac = micros % MICROS_PER_USD;
    if frac == 0 {
        return format!("${whole}");
    }
    let digits = format!("{frac:06}");
    let kept = digits.trim_end_matches('0').len().max(2);
    format!("${whole}.{}", &digits[..kept])
}

/// A decimal string (`-`, digits, optional `.` and digits) with its integer part grouped
/// by thousands: `10000` → `10,000`, `-1500.5` → `-1,500.5`. The fraction is kept as
/// written. Anything else is returned unchanged.
pub fn number(decimal: &str) -> String {
    let (sign, unsigned) = match decimal.strip_prefix('-') {
        Some(rest) => ("-", rest),
        None => ("", decimal),
    };
    let (int, frac) = match unsigned.split_once('.') {
        Some((int, frac)) => (int, Some(frac)),
        None => (unsigned, None),
    };
    let is_digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if !is_digits(int) || frac.is_some_and(|f| !is_digits(f)) {
        return decimal.to_string();
    }
    match frac {
        Some(frac) => format!("{sign}{}.{frac}", group(int)),
        None => format!("{sign}{}", group(int)),
    }
}

/// A duration as words, singular when the count is 1: `30 minutes`, `1 hour`, `2 weeks`.
pub fn duration(value: u64, unit: DurationUnit) -> String {
    let (one, many) = match unit {
        DurationUnit::Minutes => ("minute", "minutes"),
        DurationUnit::Hours => ("hour", "hours"),
        DurationUnit::Days => ("day", "days"),
        DurationUnit::Weeks => ("week", "weeks"),
        DurationUnit::Years => ("year", "years"),
    };
    counted(value, one, many)
}

/// A `YYYY-MM-DD` date as `June 30, 2027`. A string that is not a valid date in that form
/// is returned unchanged.
pub fn date(iso: &str) -> String {
    parse_date(iso).map_or_else(
        || iso.to_string(),
        |(year, month, day)| format!("{month} {day}, {year}"),
    )
}

/// An English list: `a`; `a and b`; `a, b, and c`. Empty when `items` is.
pub fn list<S: AsRef<str>>(items: &[S]) -> String {
    match items {
        [] => String::new(),
        [one] => one.as_ref().to_string(),
        [a, b] => format!("{} and {}", a.as_ref(), b.as_ref()),
        [init @ .., last] => {
            let init: Vec<&str> = init.iter().map(AsRef::as_ref).collect();
            format!("{}, and {}", init.join(", "), last.as_ref())
        }
    }
}

/// A vote threshold as written: percents as `60%`; `1/2` `half`, `1/3` `one-third`, `2/3`
/// `two-thirds`, `3/4` `three-quarters`; other fractions as `a/b`, unreduced.
pub fn threshold(num: u32, den: u32, is_percent: bool) -> String {
    if is_percent {
        return format!("{}%", count(num.into()));
    }
    match (num, den) {
        (1, 2) => "half".to_string(),
        (1, 3) => "one-third".to_string(),
        (2, 3) => "two-thirds".to_string(),
        (3, 4) => "three-quarters".to_string(),
        _ => format!("{}/{}", count(num.into()), count(den.into())),
    }
}

/// A whole number grouped by thousands: `10,000`.
pub(crate) fn count(n: u64) -> String {
    group(&n.to_string())
}

/// `n` and a noun, singular when `n` is 1: `1 seat`, `3 seats`, `1,200 holders`.
pub(crate) fn counted(n: u64, one: &str, many: &str) -> String {
    format!("{} {}", count(n), if n == 1 { one } else { many })
}

/// ASCII digits with `,` between groups of three from the right.
fn group(digits: &str) -> String {
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// The year, month name and day of a valid `YYYY-MM-DD` date.
fn parse_date(iso: &str) -> Option<(i32, &'static str, u32)> {
    let field = |from: usize, to: usize| {
        iso.get(from..to)
            .filter(|s| s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse::<u32>().ok())
    };
    if iso.len() != 10 || iso.get(4..5) != Some("-") || iso.get(7..8) != Some("-") {
        return None;
    }
    let (year, month, day) = (field(0, 4)?, field(5, 7)?, field(8, 10)?);
    let year = i32::try_from(year).ok()?;
    NaiveDate::from_ymd_opt(year, month, day)?;
    let name = MONTHS.get(usize::try_from(month).ok()?.checked_sub(1)?)?;
    Some((year, name, day))
}
