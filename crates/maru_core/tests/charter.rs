//! L04 charter tests: the golden lumen charter, every sentence template of SPEC-01 §8,
//! section order and omissions, Markdown built from sections, escaping of text from the
//! spec, and determinism. Sources are checked through `support::checking::run`, so every
//! IR rendered here also passed the schema.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod support;

use std::process::Command;

use maru_core::charter::{Section, render_markdown, render_sections, to_markdown};
use maru_core::ir::{Ir, OnClose};
use proptest::prelude::*;
use serde_json::json;
use support::LUMEN;
use support::checking::{in_goal, in_org, run, spec};
use support::ir_strategies;

/// The golden charter (SPEC-01 §8), read from the docs so it has one copy.
const GOLDEN: &str = include_str!("../../../docs/mvp/specs/examples/lumen.charter.md");

/// The IR of `src`, which must check without errors (warnings are allowed).
fn ir(src: &str) -> Ir {
    let out = run(src);
    out.ir
        .unwrap_or_else(|| panic!("errors for:\n{src}\n{:#?}", out.diagnostics))
}

fn sections(src: &str) -> Vec<Section> {
    render_sections(&ir(src))
}

/// The sections of goal `title`: its `## Goal:` section and the level-3 ones after it.
fn goal_sections<'a>(sections: &'a [Section], title: &str) -> &'a [Section] {
    let start = sections
        .iter()
        .position(|s| s.level == 2 && s.title == format!("Goal: {title}"))
        .unwrap_or_else(|| panic!("goal {title:?} in {:#?}", titles(sections)));
    let len = sections[start + 1..]
        .iter()
        .take_while(|s| s.level == 3)
        .count();
    &sections[start..=start + len]
}

fn titles(sections: &[Section]) -> Vec<(&str, u8)> {
    sections
        .iter()
        .map(|s| (s.title.as_str(), s.level))
        .collect()
}

/// The one section titled `title`.
fn section<'a>(sections: &'a [Section], title: &str) -> &'a Section {
    let found: Vec<&Section> = sections.iter().filter(|s| s.title == title).collect();
    assert_eq!(
        found.len(),
        1,
        "one section {title:?} in {:#?}",
        titles(sections)
    );
    found[0]
}

/// The only paragraph of section `title` in the charter of `src`.
fn paragraph(src: &str, title: &str) -> String {
    let all = sections(src);
    let s = section(&all, title);
    assert!(s.bullets.is_empty(), "{title} has no bullets: {s:#?}");
    assert_eq!(s.paragraphs.len(), 1, "{title} has one paragraph: {s:#?}");
    s.paragraphs[0].clone()
}

/// The bullets of section `title` in the charter of `src`.
fn bullets(src: &str, title: &str) -> Vec<String> {
    section(&sections(src), title).bullets.clone()
}

/// [`in_org`] with the template's `amend` replaced.
fn with_amend(amend: &str) -> String {
    let src = in_org("");
    assert_eq!(src.matches("amend: approve(core, 1)").count(), 1);
    src.replace("amend: approve(core, 1)", &format!("amend: {amend}"))
}

/// [`spec`] with the template mandate's body replaced by `body`.
fn with_mandate_body(body: &str) -> String {
    let src = in_goal("");
    assert_eq!(src.matches("spend llm <= usd 100 / month").count(), 1);
    src.replace("spend llm <= usd 100 / month", body)
}

/// Markdown assembled from sections independently of the crate: a heading per section
/// (`#` × level), then each paragraph, then the bullet list, blocks separated by one
/// blank line, one final newline.
fn assemble(sections: &[Section]) -> String {
    let mut blocks = Vec::new();
    for s in sections {
        let hashes = "#".repeat(usize::from(s.level));
        blocks.push(if s.title.is_empty() {
            hashes
        } else {
            format!("{hashes} {}", s.title)
        });
        blocks.extend(s.paragraphs.iter().cloned());
        if !s.bullets.is_empty() {
            let items: Vec<String> = s.bullets.iter().map(|b| format!("- {b}")).collect();
            blocks.push(items.join("\n"));
        }
    }
    blocks.join("\n\n") + "\n"
}

/// Asserts the Markdown of `ir` is built from its sections, both by the crate and by
/// [`assemble`].
fn assert_markdown_from_sections(ir: &Ir) {
    let sections = render_sections(ir);
    let md = render_markdown(ir);
    assert_eq!(md, to_markdown(&sections));
    assert_eq!(md, assemble(&sections));
}

// ---- golden ----

// L04-T01
#[test]
fn l04_t01_lumen_charter_is_byte_identical_to_the_golden_file() {
    assert_eq!(render_markdown(&ir(LUMEN)), GOLDEN);
}

// ---- org-level sections ----

// L04-T07
#[test]
fn l04_t07_membership_sentences() {
    let p = |org_extra: &str| paragraph(&in_org(org_extra), "Membership");
    assert_eq!(
        p("  members: open()"),
        "Anyone signed in to openmaru can join."
    );
    assert_eq!(
        p("  members: invite(sponsors: 1)"),
        "New members join when 1 existing member sponsors them."
    );
    assert_eq!(
        p("  members: invite(sponsors: 3)"),
        "New members join when 3 existing members sponsor them."
    );
    // The default is rendered explicitly.
    assert_eq!(
        p(""),
        "New members join when 1 existing member sponsors them."
    );
}

// L04-T08
#[test]
fn l04_t08_amend_sentences() {
    let p = |amend: &str| paragraph(&with_amend(amend), "Changing this charter");
    // vote circle / deny
    assert_eq!(
        p("vote(core, 2/3) within 7d else deny"),
        "Changes need a vote of core, passing with at least two-thirds of its holders in favour within 7 days. If the vote does not pass in time, the change is rejected."
    );
    // vote members / deny
    assert_eq!(
        p("vote(members, 1/2) within 48h else deny"),
        "Changes need a vote of all members in which at least 20% vote, passing with at least half of the votes cast in favour within 48 hours. If the vote does not pass in time, the change is rejected."
    );
    // approve / deny, 1 holder (default timeout) and 2 holders
    assert_eq!(
        p("approve(core, 1)"),
        "Changes need approval from 1 holder of core within 7 days. If not approved in time, the change is rejected."
    );
    assert_eq!(
        p("approve(core, 2) within 3d else deny"),
        "Changes need approval from 2 holders of core within 3 days. If not approved in time, the change is rejected."
    );
    // any procedure / allow
    assert_eq!(
        p("vote(core, 60%) within 1w else allow"),
        "Changes need a vote of core, passing with at least 60% of its holders in favour within 1 week. If not decided in time, the change is applied."
    );
    assert_eq!(
        p("vote(members, 3/5) within 30m else allow"),
        "Changes need a vote of all members in which at least 20% vote, passing with at least 3/5 of the votes cast in favour within 30 minutes. If not decided in time, the change is applied."
    );
    assert_eq!(
        p("approve(core, 2) within 1y else allow"),
        "Changes need approval from 2 holders of core within 1 year. If not decided in time, the change is applied."
    );
}

// L04-T09
#[test]
fn l04_t09_circle_sentences() {
    // With a term (lumen).
    assert_eq!(
        bullets(LUMEN, "Circles"),
        ["**core**: 3 seats, each held for 1 year. Holders: @mina, @jo. 1 seat is vacant."]
    );
    let src = in_org(
        "
  circle full {
    seats: 2
    holders: @ann, @bob
  }

  circle wide {
    seats: 3
    term: 6w
    holders: @ann
  }

  circle trio {
    seats: 3
    holders: @ann, @bob, @cy
  }

  circle empty {
    seats: 1
  }

  circle solo {
    seats: 1
    term: 1y
    holders: @cy
  }
",
    );
    assert_eq!(
        bullets(&src, "Circles"),
        [
            // without a term, 1 vacant
            "**core**: 3 seats with no term limit. Holders: @mina, @jo. 1 seat is vacant.",
            // 0 vacant: no vacancy sentence
            "**full**: 2 seats with no term limit. Holders: @ann, @bob.",
            // 2 vacant
            "**wide**: 3 seats, each held for 6 weeks. Holders: @ann. 2 seats are vacant.",
            // holders are listed with commas only
            "**trio**: 3 seats with no term limit. Holders: @ann, @bob, @cy.",
            // no holders
            "**empty**: 1 seat with no term limit. Holders: none. 1 seat is vacant.",
            "**solo**: 1 seat, each held for 1 year. Holders: @cy.",
        ]
    );
}

// L04-T10
#[test]
fn l04_t10_agent_sentences_and_omitted_section() {
    assert_eq!(
        bullets(LUMEN, "Agents"),
        ["**builder** is an AI agent operated by @mina, running on the hosted runtime."]
    );
    assert_eq!(
        bullets(&in_goal(""), "Agents"),
        [
            "**builder** is an AI agent operated by @mina, running on its operator's own infrastructure."
        ]
    );
    let no_agents = "org \"T\" {
  amend: approve(core, 1)

  circle core {
    seats: 1
    holders: @mina
  }

  goal g \"G\" {
    steward: core

    mandate @jo {
      spend expense <= usd 10 / month
    }
  }
}
";
    let all = sections(no_agents);
    assert!(
        all.iter().all(|s| s.title != "Agents"),
        "{:#?}",
        titles(&all)
    );
    assert!(!render_markdown(&ir(no_agents)).contains("## Agents"));
}

// ---- goal bullets ----

/// The bullets of goal `G` in [`in_goal`]`(goal_extra)`.
fn goal_bullets(goal_extra: &str) -> Vec<String> {
    bullets(&in_goal(goal_extra), "Goal: G")
}

// L04-T11
#[test]
fn l04_t11_funding_sentences() {
    let funding = |goal_extra: &str| goal_bullets(goal_extra)[1].clone();
    assert_eq!(
        funding("    fund: usd 300 / month from treasury"),
        "Receives $300 from the treasury at the start of each month. If the treasury cannot cover it, work on this goal pauses until it is funded."
    );
    assert_eq!(
        funding("    fund: usd 50 / week from treasury\n    on_underfunded: continue"),
        "Receives $50 from the treasury at the start of each week (Monday). If the treasury cannot cover it, work continues with the funds available."
    );
    assert_eq!(
        funding("    fund: usd 12.50 / day from treasury\n    on_underfunded: pause"),
        "Receives $12.50 from the treasury at the start of each day. If the treasury cannot cover it, work on this goal pauses until it is funded."
    );
    assert_eq!(
        funding("    fund: usd 1_000 once from treasury"),
        "Receives $1,000 from the treasury once, when this goal is first adopted. If the treasury cannot cover it, work on this goal pauses until it is funded."
    );
    assert_eq!(
        funding("    fund: usd 1_000 once from treasury\n    on_underfunded: continue"),
        "Receives $1,000 from the treasury once, when this goal is first adopted. If the treasury cannot cover it, work continues with the funds available."
    );
    // No fund: no underfunded sentence, whatever `on_underfunded` says (W404).
    for extra in [
        "",
        "    on_underfunded: pause",
        "    on_underfunded: continue",
    ] {
        assert_eq!(funding(extra), "Is funded only by donations.", "{extra:?}");
    }
}

// L04-T12
#[test]
fn l04_t12_closure_sentences() {
    let closure = |goal_extra: &str| goal_bullets(goal_extra)[2].clone();
    let returned = "When closed, its remaining funds return to the treasury.";
    assert_eq!(closure(""), returned);
    assert_eq!(closure("    on_close: return treasury"), returned);
    let src = spec(
        "
  goal h \"Housing fund\" {
    steward: core
  }
",
        "    on_close: transfer h",
    );
    assert_eq!(
        bullets(&src, "Goal: G")[2],
        "When closed, its remaining funds move to the goal Housing fund."
    );
    assert_eq!(bullets(&src, "Goal: Housing fund")[2], returned);
}

// L04-T13
#[test]
fn l04_t13_success_sentences() {
    let success = |line: &str| {
        let b = goal_bullets(&format!("    success: {line}"));
        assert_eq!(b.len(), 4, "{b:#?}");
        b[3].clone()
    };
    assert_eq!(
        success("metric(users) >= 10_000"),
        "Success means users reaches at least 10,000."
    );
    assert_eq!(
        success("metric(users) > 5"),
        "Success means users reaches more than 5."
    );
    assert_eq!(
        success("metric(users) <= 3"),
        "Success means users reaches at most 3."
    );
    assert_eq!(
        success("metric(users) < 0.25"),
        "Success means users reaches less than 0.25."
    );
    assert_eq!(
        success("metric(drift) == -0.5"),
        "Success means drift reaches exactly -0.5."
    );
    assert_eq!(
        success("metric(weekly_active_users) >= 10_000 by 2027-06-30"),
        "Success means weekly_active_users reaches at least 10,000 by June 30, 2027."
    );
    assert_eq!(
        success("metric(balance) >= -1_500.50 by 2030-01-01"),
        "Success means balance reaches at least -1,500.50 by January 1, 2030."
    );
    assert_eq!(
        success("metric(users) == 007"),
        "Success means users reaches exactly 7."
    );
    // No success: three bullets.
    assert_eq!(goal_bullets("").len(), 3);
}

// L04-T14
#[test]
fn l04_t14_mandate_sentences() {
    assert_eq!(
        bullets(LUMEN, "Mandates"),
        [
            "**builder** may spend up to $4,000 per month on AI models and up to $1,000 per month on compute, at most $25 per request. It may claim tasks, post evidence, and report weekly_active_users. This mandate expires on January 1, 2027.",
            "**@jo** may spend up to $500 per month on expenses. They may claim tasks, create tasks, and post evidence.",
        ]
    );
    let src = spec(
        "
  agent helper {
    operator: @jo
  }
",
        "
    mandate @ann {
      spend expense <= usd 5 / day
      spend llm <= usd 100 / month
      spend compute <= usd 20 / week
      per_request <= usd 0.50
      can: report_metric(users), claim_tasks
      expires: 2027-06-30
    }

    mandate @bob {
      can: claim_tasks
    }

    mandate @cy {
      per_request <= usd 5
    }

    mandate @dee {
      expires: 2027-01-01
    }

    mandate helper {
      can: post_evidence, create_tasks
    }",
    );
    assert_eq!(
        bullets(&src, "Mandates"),
        [
            // no capabilities: the sentence is omitted
            "**builder** may spend up to $100 per month on AI models.",
            // three spend lines joined as a list, in source order
            "**@ann** may spend up to $5 per day on expenses, up to $100 per month on AI models, and up to $20 per week on compute, at most $0.50 per request. They may report users and claim tasks. This mandate expires on June 30, 2027.",
            // no spend lines
            "**@bob** may not spend funds. They may claim tasks.",
            // a per-request cap alone allows nothing
            "**@cy** may not spend funds.",
            "**@dee** may not spend funds. This mandate expires on January 1, 2027.",
            // an agent is `It`
            "**helper** may not spend funds. It may post evidence and create tasks.",
        ]
    );
}

// L04-T15
#[test]
fn l04_t15_rule_sentences() {
    let src = in_goal(
        "
    rule spend requires approve(core, 1)
    rule spend > usd 500 requires approve(core, 2) within 48h else deny
    rule spend llm requires vote(core, 1/2) within 1d else allow
    rule spend llm > usd 0.50 requires vote(members, 3/5)
    rule spend compute requires approve(core, 1) within 30m else allow
    rule spend compute > usd 1_000 requires approve(core, 1)
    rule spend expense requires vote(members, 60%) within 2w else deny
    rule spend expense > usd 12.50 requires approve(core, 1) within 1h else allow
    rule close requires approve(core, 1)",
    );
    assert_eq!(
        bullets(&src, "Rules"),
        [
            "Any spend needs approval from 1 holder of core within 7 days; otherwise it is denied.",
            "Any spend over $500 needs approval from 2 holders of core within 48 hours; otherwise it is denied.",
            "Any AI-model spend needs a vote of core, passing with at least half of its holders in favour within 1 day; otherwise it is allowed.",
            "Any AI-model spend over $0.50 needs a vote of all members in which at least 20% vote, passing with at least 3/5 of the votes cast in favour within 7 days; otherwise it is denied.",
            "Any compute spend needs approval from 1 holder of core within 30 minutes; otherwise it is allowed.",
            "Any compute spend over $1,000 needs approval from 1 holder of core within 7 days; otherwise it is denied.",
            "Any expense needs a vote of all members in which at least 20% vote, passing with at least 60% of the votes cast in favour within 2 weeks; otherwise it is denied.",
            "Any expense over $12.50 needs approval from 1 holder of core within 1 hour; otherwise it is allowed.",
            "Closing this goal needs approval from 1 holder of core within 7 days; otherwise it stays open.",
        ]
    );
    assert_eq!(
        bullets(
            &in_goal("    rule close requires vote(core, 2/3) within 3d else allow"),
            "Rules"
        ),
        [
            "Closing this goal needs a vote of core, passing with at least two-thirds of its holders in favour within 3 days; otherwise it is closed."
        ]
    );
    assert_eq!(
        bullets(
            &in_goal("    rule close requires vote(members, 1/3) within 1w else deny"),
            "Rules"
        ),
        [
            "Closing this goal needs a vote of all members in which at least 20% vote, passing with at least one-third of the votes cast in favour within 1 week; otherwise it stays open."
        ]
    );
}

// L04-T16
#[test]
fn l04_t16_limits_sentences() {
    let limits = |src: &str| paragraph(src, "Limits");
    assert_eq!(
        limits(LUMEN),
        "Without any approval, at most $5,000 per month can be spent on this goal."
    );
    assert_eq!(
        limits(&in_goal("")),
        "Without any approval, at most $100 per month can be spent on this goal."
    );
    assert_eq!(
        limits(&with_mandate_body("spend llm <= usd 10 / day")),
        "Without any approval, at most $310 per month can be spent on this goal."
    );
    // Zero with mandates: every spend line needs approval.
    assert_eq!(
        limits(&in_goal("    rule spend llm requires approve(core, 1)")),
        "Nothing can be spent on this goal without approval."
    );
    // No spend lines at all: mandates without them, or no mandates.
    assert_eq!(
        limits(&with_mandate_body("can: claim_tasks")),
        "No one may spend from this goal."
    );
    let no_mandates = spec("\n  goal h \"H\" {\n    steward: core\n  }\n", "");
    let all = sections(&no_mandates);
    assert_eq!(
        section(goal_sections(&all, "H"), "Limits").paragraphs,
        ["No one may spend from this goal."]
    );
}

// ---- structure ----

// L04-T17
#[test]
fn l04_t17_sections_in_order_with_omissions() {
    let lumen = sections(LUMEN);
    assert_eq!(
        titles(&lumen),
        [
            ("Lumen Studio", 1),
            ("Membership", 2),
            ("Changing this charter", 2),
            ("Circles", 2),
            ("Agents", 2),
            ("Goal: Open cloud image editor", 2),
            ("Mandates", 3),
            ("Rules", 3),
            ("Limits", 3),
        ]
    );
    assert_eq!(
        lumen[0].paragraphs,
        ["Build and maintain an open, browser-based image editor."]
    );
    assert!(lumen[0].bullets.is_empty());
    assert_eq!(
        lumen[5].paragraphs,
        ["Ship a usable editor with layers, masks and export."]
    );
    assert_eq!(lumen[5].bullets.len(), 4);

    // No purposes, no agents, goals without mandates or rules, goals in source order.
    let src = "org \"Two\" {
  amend: approve(core, 1)

  circle core {
    seats: 1
    holders: @mina
  }

  goal b \"Second\" {
    steward: core
    purpose \"Do b.\"

    rule close requires approve(core, 1)
  }

  goal a \"First\" {
    steward: core

    mandate @jo {
      can: claim_tasks
    }
  }

  goal c \"Third\" {
    steward: core
  }
}
";
    let all = sections(src);
    assert_eq!(
        titles(&all),
        [
            ("Two", 1),
            ("Membership", 2),
            ("Changing this charter", 2),
            ("Circles", 2),
            ("Goal: Second", 2),
            ("Rules", 3),
            ("Limits", 3),
            ("Goal: First", 2),
            ("Mandates", 3),
            ("Limits", 3),
            ("Goal: Third", 2),
            ("Limits", 3),
        ]
    );
    assert!(all[0].paragraphs.is_empty());
    assert_eq!(all[4].paragraphs, ["Do b."]);
    assert!(all[7].paragraphs.is_empty());
    for s in &all[1..] {
        assert!(
            !s.paragraphs.is_empty() || !s.bullets.is_empty(),
            "empty section {s:#?}"
        );
    }

    // Without circles (possible only with no goals and `vote(members, …)`), `## Circles`
    // is omitted too (OQ-12).
    let commons = "org \"Commons\" {\n  members: open()\n  amend: vote(members, 1/2)\n}\n";
    assert_eq!(
        titles(&sections(commons)),
        [
            ("Commons", 1),
            ("Membership", 2),
            ("Changing this charter", 2)
        ]
    );

    // `render_markdown` is built from the sections.
    let template = in_goal("");
    for src in [LUMEN, src, commons, template.as_str()] {
        assert_markdown_from_sections(&ir(src));
    }
}

/// Whether a paragraph's text, at the start of a line after a blank line, would open a
/// Markdown block other than a paragraph (CommonMark 0.31): an ATX heading, thematic
/// break, block quote, list item, code fence, HTML block or link reference definition.
/// Leading whitespace (indented code) is checked separately.
fn opens_block(p: &str) -> bool {
    let b = p.as_bytes();
    let after = |n: usize| matches!(b.get(n), None | Some(b' ' | b'\t'));
    let hashes = b.iter().take_while(|&&c| c == b'#').count();
    let digits = b.iter().take_while(|c| c.is_ascii_digit()).count();
    let thematic = |c: u8| {
        b.iter().all(|&x| x == c || x == b' ' || x == b'\t')
            && b.iter().filter(|&&x| x == c).count() >= 3
    };
    (1..=6).contains(&hashes) && after(hashes)
        || thematic(b'-')
        || thematic(b'*')
        || thematic(b'_')
        || b.first() == Some(&b'>')
        || matches!(b.first(), Some(b'-' | b'+' | b'*')) && after(1)
        || (1..=9).contains(&digits)
            && matches!(b.get(digits), Some(b'.' | b')'))
            && after(digits + 1)
        || p.starts_with("```")
        || p.starts_with("~~~")
        || b.first() == Some(&b'<')
            && matches!(b.get(1), Some(c) if c.is_ascii_alphabetic() || matches!(c, b'/' | b'!' | b'?'))
        || b.first() == Some(&b'[')
}

/// Asserts only the renderer's own syntax shapes the Markdown: one heading line per
/// section, one `- ` line per bullet, no line breaks or edge whitespace inside any
/// string, no paragraph that opens another block, and no heading that ends in a closing
/// `#` sequence.
fn assert_structure(sections: &[Section], md: &str) {
    for s in sections {
        for t in std::iter::once(&s.title)
            .chain(&s.paragraphs)
            .chain(&s.bullets)
        {
            assert!(!t.contains(['\n', '\r']), "line break in {t:?}");
            assert_eq!(t, t.trim(), "edge whitespace in {t:?}");
        }
        for t in s.paragraphs.iter().chain(&s.bullets) {
            assert!(!t.is_empty(), "empty block in {s:#?}");
        }
        for p in &s.paragraphs {
            assert!(!opens_block(p), "paragraph opens a block: {p:?}");
        }
        let kept = s.title.trim_end_matches('#');
        assert!(
            kept.len() == s.title.len() || !(kept.is_empty() || kept.ends_with(' ')),
            "heading ends in a closing sequence: {:?}",
            s.title
        );
    }
    let headings = md.lines().filter(|l| l.starts_with('#')).count();
    assert_eq!(headings, sections.len(), "{md}");
    let items = md.lines().filter(|l| l.starts_with("- ")).count();
    let bullets: usize = sections.iter().map(|s| s.bullets.len()).sum();
    assert_eq!(items, bullets, "{md}");
    assert!(md.ends_with('\n') && !md.ends_with("\n\n"), "{md:?}");
    assert!(!md.contains("\n\n\n"), "{md:?}");
    for line in md.lines() {
        assert_eq!(line, line.trim_end(), "trailing whitespace in {md:?}");
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(500))]

    // L04-T17
    #[test]
    fn l04_t17_markdown_is_built_from_sections_for_any_ir(ir in ir_strategies::ir()) {
        assert_markdown_from_sections(&ir);
    }

    // L04 extra: text from the spec cannot add or hide structure.
    #[test]
    fn l04_text_from_the_spec_cannot_change_the_structure(ir in ir_strategies::ir()) {
        assert_structure(&render_sections(&ir), &render_markdown(&ir));
    }
}

// L04 extra: the checks above hold for every charter of this suite's sources too.
#[test]
fn l04_structure_of_example_charters() {
    for src in [LUMEN, &in_goal(""), &with_amend("vote(members, 3/5)")] {
        let ir = ir(src);
        assert_structure(&render_sections(&ir), &render_markdown(&ir));
    }
}

// ---- determinism ----

const T18_CHILD: &str = "MARU_L04_T18_CHILD";

// L04-T18
#[test]
fn l04_t18_rendering_is_deterministic_and_ignores_tz_and_lang() {
    let ir = ir(LUMEN);
    let md = render_markdown(&ir);
    let sections = render_sections(&ir);
    for _ in 0..100 {
        assert_eq!(render_markdown(&ir), md);
        assert_eq!(render_sections(&ir), sections);
    }
    assert_eq!(md, GOLDEN);
    if std::env::var_os(T18_CHILD).is_some() {
        return;
    }
    // Run this test again in child processes with other time zones and locales.
    let exe = std::env::current_exe().unwrap();
    for (tz, lang) in [
        ("Pacific/Kiritimati", "de_DE.UTF-8"),
        ("America/St_Johns", "ar_SA.UTF-8"),
        ("Asia/Kolkata", "ja_JP.UTF-8"),
        ("UTC", "C"),
    ] {
        let out = Command::new(&exe)
            .args([
                "--exact",
                "l04_t18_rendering_is_deterministic_and_ignores_tz_and_lang",
                "--test-threads=1",
            ])
            .env(T18_CHILD, "1")
            .env("TZ", tz)
            .env("LANG", lang)
            .env("LC_ALL", lang)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(
            out.status.success() && stdout.contains("1 passed"),
            "TZ={tz} LANG={lang}:\n{stdout}\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

// ---- edge cases ----

/// The org purpose paragraphs when lumen's purpose is `text`.
fn purpose(text: &str) -> Vec<String> {
    let mut ir = ir(LUMEN);
    ir.org.purpose = Some(text.to_string());
    render_sections(&ir)[0].paragraphs.clone()
}

// L04 extra (OQ-12): text from the spec is one line and renders literally.
#[test]
fn l04_text_from_the_spec_is_escaped() {
    let same = "Build and maintain an open, browser-based image editor.";
    for (input, output) in [
        // Inline syntax.
        ("*bold* and **strong**", "\\*bold\\* and \\*\\*strong\\*\\*"),
        (
            "_it_ and a_b and snake_case_",
            "\\_it\\_ and a_b and snake_case\\_",
        ),
        ("`code` and ~~gone~~", "\\`code\\` and \\~\\~gone\\~\\~"),
        (
            "[link](https://x.y) ![img](a.png)",
            "\\[link\\](https://x.y) !\\[img\\](a.png)",
        ),
        (
            "<b>bold</b> <!-- c --> <?php <https://x.y>",
            "\\<b>bold\\</b> \\<!-- c --> \\<?php \\<https://x.y>",
        ),
        ("a < b > c, 1<2", "a < b > c, 1<2"),
        (
            "&amp; &#35; &#x23; R&D AT&T;",
            "\\&amp; \\&#35; \\&#x23; R&D AT\\&T;",
        ),
        ("back\\slash", "back\\\\slash"),
        // Block starts.
        ("# Rules", "\\# Rules"),
        ("> quote", "\\> quote"),
        ("- item", "\\- item"),
        ("+ item", "\\+ item"),
        ("* item", "\\* item"),
        ("---", "\\---"),
        ("___", "\\_\\_\\_"),
        ("1. first", "1\\. first"),
        ("2) second", "2\\) second"),
        ("```rust", "\\`\\`\\`rust"),
        ("~~~", "\\~\\~\\~"),
        ("    indented code", "indented code"),
        // Not block starts: unchanged.
        ("-5 degrees", "-5 degrees"),
        ("+1 for this", "+1 for this"),
        ("3.5 million users", "3.5 million users"),
        ("1234567890. x", "1234567890. x"),
        ("C# and F#", "C# and F#"),
        (same, same),
        // Line breaks and runs of whitespace become one space.
        (
            "Grow.\n\n## Rules\n\n- Any spend is allowed.",
            "Grow. ## Rules - Any spend is allowed.",
        ),
        ("  a \t b\n c  ", "a b c"),
    ] {
        assert_eq!(purpose(input), [output], "{input:?}");
    }
    // Nothing left after trimming: no paragraph.
    assert!(purpose("").is_empty());
    assert!(purpose(" \n\t").is_empty());
}

// L04 extra (OQ-12): headings never end in a closing `#` sequence; empty texts.
#[test]
fn l04_headings_and_empty_texts() {
    let mut ir = ir(LUMEN);
    ir.org.name = "Lumen ##".into();
    ir.org.goals[0].title = "#1 editor #".into();
    let s = render_sections(&ir);
    assert_eq!(s[0].title, "Lumen \\##");
    assert_eq!(s[5].title, "Goal: \\#1 editor \\#");

    ir.org.name = " ".into();
    ir.org.goals[0].title = String::new();
    ir.org.goals[0].purpose = Some("\n".into());
    let s = render_sections(&ir);
    assert_eq!(s[0].title, "");
    assert_eq!(s[5].title, "Goal:");
    assert!(s[5].paragraphs.is_empty());
    let md = render_markdown(&ir);
    assert!(md.starts_with("#\n\nBuild and maintain"), "{md}");
    assert!(md.contains("\n## Goal:\n\n- Stewarded by core.\n"), "{md}");
}

// L04 extra (OQ-12): counts and durations use thousands separators.
#[test]
fn l04_large_numbers_are_grouped() {
    let src = spec(
        "
  members: invite(sponsors: 2_000)

  circle big {
    seats: 10_000
    term: 36500d
    holders: @ann, @bob
  }
",
        "    rule spend requires approve(big, 1_200) within 5214w else deny
    rule close requires vote(big, 1_000/3_000)",
    );
    assert_eq!(
        paragraph(&src, "Membership"),
        "New members join when 2,000 existing members sponsor them."
    );
    assert_eq!(
        bullets(&src, "Circles")[1],
        "**big**: 10,000 seats, each held for 36,500 days. Holders: @ann, @bob. 9,998 seats are vacant."
    );
    assert_eq!(
        bullets(&src, "Rules"),
        [
            "Any spend needs approval from 1,200 holders of big within 5,214 weeks; otherwise it is denied.",
            "Closing this goal needs a vote of big, passing with at least 1,000/3,000 of its holders in favour within 7 days; otherwise it stays open.",
        ]
    );
    assert_eq!(
        paragraph(&src, "Limits"),
        "Nothing can be spent on this goal without approval."
    );
}

// L04 extra: the structured form serializes as SPEC-01 §8 shows, plus `level`.
#[test]
fn l04_sections_serialize_in_the_spec_shape() {
    let s = sections(LUMEN);
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(
        v[1],
        json!({
            "section": "Membership",
            "level": 2,
            "paragraphs": ["New members join when 1 existing member sponsors them."],
            "bullets": []
        })
    );
    assert_eq!(serde_json::from_value::<Vec<Section>>(v).unwrap(), s);
}

// L04 extra: IRs the checker never emits still render (L07 renders IR JSON).
#[test]
fn l04_renders_irs_the_checker_never_emits() {
    let mut ir = ir(LUMEN);
    ir.org.circles[0].holders = vec!["a1".into(), "b2".into(), "c3".into(), "d4".into()];
    let goal = &mut ir.org.goals[0];
    goal.on_close = OnClose::Transfer {
        goal: "ghost".into(),
    };
    goal.mandates[0].expires = Some("soon".into());
    let s = render_sections(&ir);
    // More holders than seats: no vacancy sentence.
    assert_eq!(
        s[3].bullets,
        ["**core**: 3 seats, each held for 1 year. Holders: @a1, @b2, @c3, @d4."]
    );
    // An unknown transfer target is named by its id.
    assert_eq!(
        s[5].bullets[2],
        "When closed, its remaining funds move to the goal ghost."
    );
    // A malformed date is shown as written.
    assert!(
        s[6].bullets[0].ends_with(" This mandate expires on soon."),
        "{}",
        s[6].bullets[0]
    );
}
