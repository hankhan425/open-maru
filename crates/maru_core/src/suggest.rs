//! "Did you mean" suggestions for unknown references (SPEC-01 §5).

/// The largest edit distance for which a name is suggested.
pub const MAX_DISTANCE: usize = 2;

/// Levenshtein distance between `a` and `b`, counted in Unicode scalar values.
pub fn levenshtein(_a: &str, _b: &str) -> usize {
    unimplemented!("L03")
}

/// The candidate closest to `name` within [`MAX_DISTANCE`] edits; on a tie, the first in
/// iteration order. `None` when nothing is that close.
pub fn did_you_mean<'a>(
    _name: &str,
    _candidates: impl IntoIterator<Item = &'a str>,
) -> Option<&'a str> {
    unimplemented!("L03")
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
