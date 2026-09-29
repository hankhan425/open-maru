//! Source positions and spans (SPEC-01 §5 diagnostic shape).

use std::ops::Range;

use serde::{Deserialize, Serialize};

/// A position in the source text.
///
/// `line` and `col` are 1-based; `col` counts Unicode scalar values from the start of the
/// line. `offset` is the 0-based UTF-8 byte offset into the source as given (before any
/// CRLF normalization), so `&src[span.range()]` slices a node's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Pos {
    /// 1-based line number.
    pub line: u32,
    /// 1-based column, counted in Unicode scalar values.
    pub col: u32,
    /// 0-based UTF-8 byte offset.
    pub offset: usize,
}

impl Pos {
    /// The position of the first character of a source.
    pub const START: Pos = Pos {
        line: 1,
        col: 1,
        offset: 0,
    };
}

/// A half-open range of source text: `start` is the first character, `end` is just past
/// the last one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Span {
    /// Position of the first character.
    pub start: Pos,
    /// Position just past the last character.
    pub end: Pos,
}

impl Span {
    /// A span from `start` to `end`.
    pub const fn new(start: Pos, end: Pos) -> Span {
        Span { start, end }
    }

    /// An empty span at `pos` (used for errors at end of file).
    pub const fn point(pos: Pos) -> Span {
        Span {
            start: pos,
            end: pos,
        }
    }

    /// The smallest span covering both `self` and `other`.
    pub fn to(self, other: Span) -> Span {
        Span {
            start: if other.start.offset < self.start.offset {
                other.start
            } else {
                self.start
            },
            end: if other.end.offset > self.end.offset {
                other.end
            } else {
                self.end
            },
        }
    }

    /// The byte range of this span, for slicing the source.
    pub fn range(&self) -> Range<usize> {
        self.start.offset..self.end.offset
    }
}
