# F02 · World map (PixiJS)

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F01, C03, C05 | L | 9 |

**Read first:** SPEC-08 §1, §3 (World), §4 (sim/draw split), §5; SPEC-07 `/public/world`, `public:world` channel; the prototype's canvas behavior.
**Paths:** `web/src/features/world/**`

## Goal
The home screen: a calm, living map of orgs and their goals. Pure simulation modules are tested; Pixi only draws.

## Deliverables
- `sim/`: `layout.ts` (seeded initial positions), `physics.ts` (drift, collision, edge springs), `camera.ts`, `hit.ts`, `nav.ts` (directional keyboard selection), `pulses.ts`.
- `WorldCanvas` (PixiJS v8) drawing orgs, goal satellites, shared-member edges, pulses; `WorldList` accessible fallback; search, legend toggles, theme-aware colors.

## Tests to write first
- [ ] **F02-T01** Same data → same initial positions (seed = hash of org id); different ids → different positions.
- [ ] **F02-T02** Org radius = k·√members clamped [min, max]; goal radius from monthly funding clamped.
- [ ] **F02-T03** After 300 physics steps, no two of 50 fixture nodes overlap (distance ≥ r₁ + r₂ + gap).
- [ ] **F02-T04** Hit-testing returns the topmost node; goals win over their org; empty space → null.
- [ ] **F02-T05** Zoom around the cursor keeps the world point under the cursor fixed; pan is clamped to world bounds.
- [ ] **F02-T06** Arrow keys select the nearest node within the pressed direction's 90° cone; `Enter` navigates to the org; `Esc` clears.
- [ ] **F02-T07** Search matches name or slug (case/diacritic-insensitive) and focuses the camera on the result.
- [ ] **F02-T08** Legend toggles hide edges and/or goal satellites.
- [ ] **F02-T09** Pulses: events enqueue animations capped at 30 concurrent; reduced motion → no pulses, "recent activity" list still updates.
- [ ] **F02-T10** List view renders the same orgs, keyboard-navigable; toggle persists in the URL.
- [ ] **F02-T11** Mount/unmount of `WorldCanvas` (Pixi mocked) calls `destroy` and removes listeners.
- [ ] **F02-T12** Bench (`vitest bench`): one physics step for 500 nodes < 4 ms.

## Out of scope
Cross-org relationships beyond shared members (post-MVP).
