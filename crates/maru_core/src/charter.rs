//! The charter: a deterministic plain-English reading of an [`Ir`] (SPEC-01 §8), as
//! structured [`Section`]s and as Markdown built from them. The golden output for the
//! canonical example is `docs/mvp/specs/examples/lumen.charter.md`.

use serde::{Deserialize, Serialize};

use crate::ir::Ir;

/// One charter section: a heading and the paragraphs and bullets under it.
///
/// Every string is Markdown inline text: ids are set in `**bold**`, and text taken from
/// the spec is escaped so that it renders literally.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    /// The heading text; `"section"` in JSON (SPEC-01 §8).
    #[serde(rename = "section")]
    pub title: String,
    /// The heading level: 1 for the org, 2 for org-level sections and goals, 3 within a
    /// goal.
    pub level: u8,
    /// Paragraphs, in order. They come before the bullets.
    pub paragraphs: Vec<String>,
    /// Bullet items without their `- ` marker, in order.
    pub bullets: Vec<String>,
}

/// The charter of `ir` as sections, in the order of SPEC-01 §8.
pub fn render_sections(_ir: &Ir) -> Vec<Section> {
    unimplemented!("L04")
}

/// Markdown for `sections`: each heading, paragraph and bullet list is one block, blocks
/// are separated by a blank line, and the text ends with one newline.
pub fn to_markdown(_sections: &[Section]) -> String {
    unimplemented!("L04")
}

/// The charter of `ir` as Markdown: [`to_markdown`] of [`render_sections`].
pub fn render_markdown(ir: &Ir) -> String {
    to_markdown(&render_sections(ir))
}
