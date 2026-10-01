//! "Did you mean" suggestions for unknown references (SPEC-01 §5).

/// The largest edit distance for which a name is suggested.
pub const MAX_DISTANCE: usize = 2;

/// Levenshtein distance between `a` and `b`, counted in Unicode scalar values.
pub fn levenshtein(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0; b.len() + 1];
    for (i, ca) in a.chars().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let substitute = prev[j] + usize::from(ca != *cb);
            cur[j + 1] = substitute.min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// The distance between `a` and `b` if it is at most [`MAX_DISTANCE`]. Names differing in
/// length by more than that are skipped without computing anything.
fn close(a: &str, b: &str) -> Option<usize> {
    let (la, lb) = (a.chars().count(), b.chars().count());
    if la.abs_diff(lb) > MAX_DISTANCE {
        return None;
    }
    Some(levenshtein(a, b)).filter(|d| *d <= MAX_DISTANCE)
}

/// The candidate closest to `name` within [`MAX_DISTANCE`] edits; on a tie, the first in
/// iteration order. `None` when nothing is that close.
pub fn did_you_mean<'a>(
    name: &str,
    candidates: impl IntoIterator<Item = &'a str>,
) -> Option<&'a str> {
    let mut best: Option<(usize, &'a str)> = None;
    for candidate in candidates {
        if let Some(d) = close(name, candidate) {
            if best.is_none_or(|(b, _)| d < b) {
                best = Some((d, candidate));
            }
        }
    }
    best.map(|(_, c)| c)
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
}
