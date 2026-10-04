# F03 · Org page

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F01, C03 | M | 8 |

**Read first:** SPEC-08 §1, §3 (Org); SPEC-07 org rows; SPEC-02 §3.2 (holder consent), §3.5 (membership).
**Paths:** `web/src/features/org/**`, `web/src/components/maru-highlight/**`

## Goal
One page explains an org: what it's for, who governs it, how rules read in plain English and in source, and its goals.

## Deliverables
- `/o/:slug` with header, purpose, "How it's governed" (Charter / Source toggle, version selector), circles, goals list, membership action, related orgs, suspended banner.
- Read-only maru syntax highlighter (token classes shared with F04).

## Tests to write first
- [ ] **F03-T01** Lumen fixture: name, purpose, circle `core` with @mina effective, @jo pending (if fixture says so), 1 vacancy; goal row with funding bar and status chip.
- [ ] **F03-T02** Charter view renders API sections (every string through `MarkdownInline`, SPEC-08 §4); Source view highlights keywords/strings/numbers/handles; toggle reflected in `?view=source` and restored on load.
- [ ] **F03-T03** Version selector lists versions; choosing v1 shows v1's charter and a "not current" note.
- [ ] **F03-T04** Membership: `open` → Join button; `invite` → explanation plus Sponsor action for members; pending holder sees Accept/Decline banner.
- [ ] **F03-T05** Related orgs list (shared members) links to their pages.
- [ ] **F03-T06** Suspended org shows the notice and hides actions.
- [ ] **F03-T07** Unknown slug → not-found state.
- [ ] **F03-T08** Axe: no violations.

## Out of scope
Editing (F04), goal detail (F06).
