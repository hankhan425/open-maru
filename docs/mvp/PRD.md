# PRD — openmaru MVP

## 1. Problem

Organizations increasingly want AI agents to do real, funded, ongoing work. Today there is no shared, precise way to say *who may do what with which money toward which goal*, no way to make agents accountable to those rules, and no way for supporters to see exactly how their money was used.

## 2. Product in one sentence

Organizations describe themselves in **maru**, a precise, human-readable language; openmaru enforces that description, runs funded goals with people and agents under explicit mandates, and publishes a live, provenance-tagged ledger of every cent.

## 3. The core loop (the MVP must prove this end to end)

```
Fund → the org funds a goal with its own money (ledger); once it has a track record,
       donors pledge to pay for accepted work, and later may donate up front
      → governance issues a mandate to an agent (spec)
      → agent works: claims tasks, calls models through the metered gateway
      → every call is authorized, held, and posted to the ledger (verified tier)
      → agent posts evidence; steward accepts the work
      → pledges pay back the accepted work each month
      → public goal page shows progress, spend by provenance tier, and evidence live
```

## 4. Wedge

Agent-operated open-source software goals (example: an open cloud image editor). Reasons: agents can do this work today; spend is almost entirely LLM and compute, so it is metered and *verified*; outputs (PRs, deploys, usage) are verifiable; no beneficiary PII. Community orgs can use the language and world map, but the money loop is proven on software goals.

## 5. Users

| User | Needs |
|---|---|
| **Founder / steward** (human) | Write the org's rules, fund goals, approve work and spend, stop things instantly |
| **Member** (human) | Understand the rules, vote on changes, contribute, claim expenses |
| **Agent operator** (human) | Register an agent, give it a scoped token, point it at the gateway, see its spend |
| **Agent** (AI) | Machine-readable goal/spec, tasks to claim, a token, a CLI and MCP tools, clear denial reasons |
| **Supporter / donor** | Find goals, donate in a minute, see exactly where money went |
| **Public visitor** | Browse orgs and goals, read charters, verify the ledger |

## 6. MVP scope

**In**
- maru-lang v0: orgs, membership (open / invite), circles with holders and terms, agents, goals, funding, mandates, approval rules, amendment rule, success metric, underfunded/close behavior. Every construct is enforced — nothing decorative.
- Deterministic charter (plain English) rendering, semantic diff, static limit analysis ("max spend without approval").
- Toolchain from one Rust crate: server (NIF), browser (WASM), CLI.
- Accounts: passkeys, GitHub, Google; CLI device login; personal access tokens.
- Leaving and silence: anyone may leave at any time; people silent for 90 days stop counting toward decisions; an amend decision shrinks to the people who remain; member-wide votes count votes cast, with 20% turnout and members of 30 days; anyone can fork an org's spec into a new org (C04, C07; OQ-16).
- Outside money: an org that spends only its own funds has no extra rules. Pledges (donors pay for accepted work) and upfront donations are earned through funding tiers, with a cap on unspent outside money, a waiting period with donor exit before rule changes, and dormancy that refunds unspent money when stewards go silent (P04, P05; SPEC-05 §8; OQ-16).
- Orgs with versioned, content-addressed specs; amendment proposals decided by the spec's own `amend` rule.
- Decisions engine (approve-N / vote-threshold, deadlines, default outcomes) used for amendments, gated spend, and goal closure.
- Ledger: double-entry, integer micro-USD, two-phase holds, linked transfers, balance constraints, idempotency, hash chain, daily public checkpoints.
- Goals: monthly/one-time funding from treasury, underfunded handling, pause/resume (kill switch), closure with fund disposition, success metric reporting.
- Mandates enforced via Cedar; mandate tokens via Biscuit (attenuable, revocable).
- Stripe Connect (Standard accounts, direct charges): onboarding, pledges and one-time and monthly donations earmarked to a goal, fee breakdown, refunds, daily reconciliation.
- Metered LLM gateway: Anthropic Messages and OpenAI Chat Completions, BYOK (goal's own provider keys), streaming, holds, exact posting.
- Tasks, leases, evidence, steward review.
- Hosted runtime via E2B (BYOK), compute metering, session supervision.
- Interfaces: REST API, Phoenix Channels, MCP server, `maru` CLI.
- Web: world map, org page (charter/source), spec editor with live checking, decisions inbox, goal page with live ledger, donation flow, agents/mandates/secrets admin.
- Public, unauthenticated read APIs and pages for orgs, goals, ledger, checkpoints.

**Out (post-MVP)**
- Crypto rails and wallets (ledger stays rail-agnostic). Optional: anchoring checkpoints on Solana (task G05).
- Virtual cards, vendor payments through openmaru.
- Paying people through the platform (reimbursements are approved on-platform and paid off-platform with proof).
- Tax-deductible giving, fiscal hosting.
- Cross-org flows, inheritance/federations, forks that carry funds, members or history, relationships beyond shared members.
- Spec settings for the outside-money rules (orgs may later only make them stricter), all-or-nothing pledges, donations to the treasury.
- Quadratic voting, elections, apply-to-join membership.
- Physical-world goals, beneficiary data.
- Field-level private visibility (MVP: everything public except receipts, secrets, donor identity).

## 7. Success criteria for MVP

- A new user creates an org, writes a valid spec, and funds a goal with their own money in under 15 minutes (Stripe is needed only for outside money).
- A donor completes a pledge or a donation in under 60 seconds; the goal page reflects it within 10 seconds of the Stripe webhook.
- A goal holding outside money whose stewards go silent closes to new money by day 45 and refunds what is unspent by day 90.
- A BYO agent (e.g. Claude Code pointed at the gateway) completes a task; 100% of its model spend appears on the public ledger as *verified* with model and token counts.
- A spend exceeding a mandate or budget is refused with a specific, machine-readable reason.
- Pausing a goal stops all its sessions and blocks all its spend within 5 seconds.
- The hash chain verifies from genesis for every day since launch.

## 8. Glossary

| Term | Meaning |
|---|---|
| **Spec** | An org's maru source file. Versioned; each version is content-addressed by the SHA-256 of its canonical formatted source. |
| **IR** | Normalized JSON produced by the checker from a spec. All runtimes read the IR, never raw source. |
| **Charter** | Plain-English rendering of the IR. Deterministic; never produced by an LLM. |
| **Circle** | A named group of seats held by people (`@handles`), with an optional term. |
| **Holder** | A person currently holding a seat in a circle (term not expired). |
| **Principal** | Anyone who can act: a person (`@handle`) or an agent (declared in the spec). |
| **Agent** | A non-human principal declared in the spec, with an accountable human operator. |
| **Goal** | A durable, org-owned mission with its own funds account, steward circle, mandates, rules, tasks, and evidence. Resources belong to the goal, never to workers. |
| **Steward** | The circle accountable for a goal. |
| **Mandate** | A grant, inside a goal, giving one principal specific capabilities and spend limits per period. |
| **Mandate token** | A Biscuit token proving the bearer acts under a mandate. Attenuable and revocable. |
| **Rule** | An approval gate: a class of actions that requires a decision before it executes. |
| **Decision** | A running procedure (`approve(circle, N)` or `vote(circle, threshold)`) with a deadline and default outcome. |
| **Proposal** | A decision whose effect is applying a new spec version. |
| **Fork** | A new org started from a copy of another org's active spec. Nothing else is copied. |
| **Treasury** | The org's unearmarked funds account; it holds own funds only. |
| **Own funds** | Money an org's people put in themselves, recorded by an administrator. The platform doesn't see it. |
| **Outside money** | Pledges and donations from anyone through openmaru; protected by SPEC-05 §8. |
| **Pledge** | A donor's monthly cap for a goal; charged after the fact for up to 80% of the goal's accepted spend. |
| **Accepted spend** | Verified spend on tasks accepted by someone other than the worker or its operator. |
| **Funding tier** | What outside money an org has earned: 0 own funds only, 1 pledges, 2 upfront donations. |
| **Silent** | No sign-in or other activity for 90 days; a silent person stops counting toward decisions until they return. |
| **Dormant** | A goal whose stewards were silent for 90 days while it held outside money; unspent outside money is refunded. |
| **Hold** | A pending ledger transfer reserving funds/budget until posted or voided. |
| **Provenance tier** | How a spend is known: **verified** (platform-metered or platform-observed), **evidenced** (receipt attached), **attested** (someone's claim). |
| **Lease** | A time-limited claim on a task by a principal, kept alive by heartbeats. |
| **Session** | A hosted-runtime sandbox run for a task, metered as compute. |
| **BYOK** | Bring your own key: provider credentials belong to the goal; providers bill the org directly. |
