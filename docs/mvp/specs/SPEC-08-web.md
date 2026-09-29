# SPEC-08 — Web app

## 1. Principles

1. **Legibility beats spectacle.** Every number links to the ledger entries behind it. Money always shows its provenance tier.
2. **Game-like = spatial, alive, and progressive.** Navigate a world, watch funds and agents move, see goals advance like quests. No points, badges, streaks, or leaderboards for donations.
3. **Same object, two readings.** Anything governed by the spec can be read as charter or as source.
4. **Calm by default.** Motion is purposeful and honors `prefers-reduced-motion`. Serious goals must never feel like a mobile game.
5. **Keyboard first.** `/` search, arrows browse, `Enter` expand, `Esc` back (from the prototype), `?` shows shortcuts.

## 2. Design tokens (from the prototype, `Openmaru_Landing.html`)

| Token | Value |
|---|---|
| `--bg` | `#F2EEE6` |
| `--panel` | `rgba(246,243,236,0.78)` + `backdrop-filter: blur(12px)` |
| `--ink` | `#2A2723` |
| `--ink-muted` | `#6F685E` · `--ink-faint` `#9A9186` · `--ink-body` `#5A544B` |
| `--accent` | `#A4552F` (kicker labels, numbers in code) |
| `--code-string` | `#5B7048` · `--code-keyword` `#3E5A7A` · `--code-punct` `#A39A8D` |
| `--line` | `rgba(42,39,35,0.14)` |
| Fonts | Display `Instrument Serif`; UI `Instrument Sans`; code/labels `JetBrains Mono` (self-hosted) |
| Radii | card 26px · input/button 14px · pill 19px · menu 16px |
| Themes | `graphite` (default), `cyanotype` (`#EDF0EE` / ink `rgb(30,58,102)`), `mycelium` (`#F2ECDF` / ink `rgb(70,58,45)` + category palette) |
| Dark mode | derived palette per theme (ink/bg swapped with warm near-black `#1D1B18`), required for all non-canvas UI |

Provenance badges: **verified** `●` solid ink · **evidenced** `◐` half · **attested** `○` outline, always with a text label on first use in a view and a tooltip explaining the tier.

## 3. Screens

| Route | Screen | Key contents | Task |
|---|---|---|---|
| `/` | World | PixiJS canvas: orgs as drifting nodes sized by `sqrt(members)`, goals as satellites sized by monthly funding, shared-member edges, live pulses on spend/donation. Search, legend toggles, theme switch, list-view fallback. Sign-in card overlay (as in prototype). | F02 |
| `/signin`, `/device` | Auth | Email + passkey, GitHub, Google; first-login handle picker; device-code approval | F01 |
| `/o/:slug` | Org | Name, purpose, **How it's governed** with `Charter / Source` toggle, circles (holders, vacancies, pending acceptances), goals with funding bars and status, membership action (join / request sponsorship), related (shared members) | F03 |
| `/o/:slug/edit` | Spec editor | CodeMirror 6 with maru highlighting, live diagnostics from WASM (≤ 50 ms debounce), charter preview, diff vs active version with loosens/tightens markers and limits change, `Propose change` (title, rationale) | F04 |
| `/o/:slug/proposals`, `/decisions/:id`, `/inbox` | Decisions | Proposal diff + charter delta; spend decision details; ballots, required count, countdown; approve/reject; holder acceptance items | F05 |
| `/o/:slug/g/:goal` | Goal | Status, period funding meter (allocated/spent/held/available), success metric progress, spend by category and tier, live ledger feed, tasks board (open/claimed/review/done), evidence, activity, the goal's charter section, **Donate** | F06 |
| `/o/:slug/g/:goal/ledger` | Goal ledger | Filterable, paginated entries; CSV export; link to checkpoints | F06 |
| `/donate/...`, `/donations/:id/thanks` | Donation | Amount presets, monthly toggle, public-name opt-in, Stripe Checkout redirect; receipt with fee breakdown and "where it went" | F07 |
| `/o/:slug/settings` | Settings | Payments onboarding/status, reconciliation status (admins); goal secrets (write-only); agents, mandates, tokens (mint shows once with copy + setup snippet for Claude Code / OpenAI SDK / MCP), sessions, **Pause goal** and **Stop agent** with confirmation | F07, F08 |
| `/new` | Create org | Starter template in the editor, slug picker, create | F04 |
| `/ledger` | Public ledger | Checkpoints list, verify instructions | F06 |

## 4. Architecture

- Feature folders: `web/src/features/{world,org,editor,decisions,goal,donate,settings,auth}`.
- Server state via TanStack Query; realtime events from Channels update the query cache (`queryClient.setQueryData`) rather than refetching everything.
- `web/src/lib/maru` wraps the WASM package: `check`, `format`, `render`, `diff`; loaded lazily on the editor route only.
- Canvas logic (layout, physics, hit-testing, camera) lives in pure TS modules under `features/world/sim/` and is unit-tested without Pixi; the Pixi layer only draws.
- Money formatting matches the charter helpers exactly (shared test vectors from SPEC-01 §8).
- Routes are code-split; world canvas and editor are separate chunks.

## 5. Quality bars

- Lighthouse (mobile) ≥ 90 performance on org and goal pages; world route interactive < 2.5 s on mid-range laptop.
- WCAG 2.2 AA for all DOM UI; the world has a list-view equivalent reachable by keyboard.
- No layout shift from live updates (reserve space for feeds).
