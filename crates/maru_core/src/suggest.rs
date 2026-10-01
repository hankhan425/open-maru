//! "Did you mean" suggestions for unknown references (SPEC-01 §5).

/// The largest edit distance for which a name is suggested.
pub const MAX_DISTANCE: usize = 2;

/// Levenshtein distance between `a` and `b`, counted in Unicode scalar values.
pub fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    distance(&a, &b, &mut Vec::new(), &mut Vec::new())
}

/// Levenshtein distance with caller-provided row buffers, so repeated lookups do not
/// allocate.
fn distance(a: &[char], b: &[char], prev: &mut Vec<usize>, cur: &mut Vec<usize>) -> usize {
    prev.clear();
    prev.extend(0..=b.len());
    cur.clear();
    cur.resize(b.len() + 1, 0);
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let substitute = prev[j] + usize::from(ca != cb);
            cur[j + 1] = substitute.min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        std::mem::swap(prev, cur);
    }
    prev[b.len()]
}

/// The candidate closest to `name` within [`MAX_DISTANCE`] edits; on a tie, the first in
/// iteration order. `None` when nothing is that close.
pub fn did_you_mean<'a>(
    name: &str,
    candidates: impl IntoIterator<Item = &'a str>,
) -> Option<&'a str> {
    Suggester::new(u64::MAX).did_you_mean(name, candidates)
}

/// Suggestion lookups that share a work budget, so that a source with thousands of
/// unknown references and thousands of declared names cannot make checking slow.
///
/// Each candidate costs one step, plus `len(name) × len(candidate)` (in characters) when
/// the lengths are close enough to compute the distance. A lookup that would overspend
/// returns `None`, and so does every later one. Results depend only on the lookups and
/// their order, so checking stays deterministic.
#[derive(Debug, Clone)]
pub struct Suggester {
    budget: u64,
    // Reused buffers.
    name: Vec<char>,
    candidate: Vec<char>,
    prev: Vec<usize>,
    cur: Vec<usize>,
}

impl Suggester {
    /// The checker's budget: a few milliseconds of work. A spec with a few dozen names
    /// uses a tiny fraction of it; only sources with thousands of unknown references and
    /// thousands of declared names reach it.
    pub const CHECK_BUDGET: u64 = 4_000_000;

    /// A suggester that may spend `budget` steps.
    pub fn new(budget: u64) -> Suggester {
        Suggester {
            budget,
            name: Vec::new(),
            candidate: Vec::new(),
            prev: Vec::new(),
            cur: Vec::new(),
        }
    }

    /// Like [`did_you_mean`], or `None` once the budget is spent.
    pub fn did_you_mean<'a>(
        &mut self,
        name: &str,
        candidates: impl IntoIterator<Item = &'a str>,
    ) -> Option<&'a str> {
        self.name.clear();
        self.name.extend(name.chars());
        let len = self.name.len();
        let mut best: Option<(usize, &'a str)> = None;
        for candidate in candidates {
            self.candidate.clear();
            self.candidate.extend(candidate.chars());
            let other = self.candidate.len();
            let near = len.abs_diff(other) <= MAX_DISTANCE;
            let cells = if near {
                u64::try_from(len.saturating_mul(other)).unwrap_or(u64::MAX)
            } else {
                0
            };
            let cost = cells.saturating_add(1);
            if cost > self.budget {
                self.budget = 0;
                return None;
            }
            self.budget -= cost;
            if !near {
                continue;
            }
            let d = distance(&self.name, &self.candidate, &mut self.prev, &mut self.cur);
            if d <= MAX_DISTANCE && best.is_none_or(|(b, _)| d < b) {
                best = Some((d, candidate));
            }
        }
        best.map(|(_, c)| c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // L03 extra: the edit distance behind "did you mean" (SPEC-01 §5).
    #[test]
    fn l03_levenshtein_distance() {
        assert_eq!(levenshtein("", ""), 0);
        assert_eq!(levenshtein("core", "core"), 0);
        assert_eq!(levenshtein("cor", "core"), 1);
        assert_eq!(levenshtein("core", "cpre"), 1);
        assert_eq!(levenshtein("ocre", "core"), 2);
        assert_eq!(levenshtein("kitten", "sitting"), 3);
        assert_eq!(levenshtein("", "abc"), 3);
        assert_eq!(levenshtein("é", "e"), 1);
    }

    // L03 extra: the closest candidate within 2 edits, first on a tie.
    #[test]
    fn l03_did_you_mean_picks_the_closest() {
        assert_eq!(did_you_mean("cor", ["ops", "core"]), Some("core"));
        assert_eq!(did_you_mean("xyz", ["core"]), None);
        assert_eq!(did_you_mean("abcd", ["ab", "abc"]), Some("abc"));
        assert_eq!(did_you_mean("g3", ["g1", "g2"]), Some("g1"));
        assert_eq!(did_you_mean("core", Vec::<&str>::new()), None);
    }

    // L03 extra: lookups share a work budget; once it is spent they return `None`.
    #[test]
    fn l03_suggester_stops_when_its_budget_is_spent() {
        // "cor" against "ops" and "core": 1 + 9 and 1 + 12 character comparisons.
        let mut s = Suggester::new(23);
        assert_eq!(s.did_you_mean("cor", ["ops", "core"]), Some("core"));
        assert_eq!(s.did_you_mean("cor", ["core"]), None);
        assert_eq!(s.did_you_mean("cor", ["core"]), None);
        let mut s = Suggester::new(22);
        assert_eq!(s.did_you_mean("cor", ["ops", "core"]), None);
        // Names too different in length cost one step each.
        let mut s = Suggester::new(5);
        assert_eq!(s.did_you_mean("a", ["abcd", "abcde", "ab"]), Some("ab"));
    }
}
