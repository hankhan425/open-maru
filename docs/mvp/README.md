# openmaru MVP — specs & tasks

openmaru lets organizations describe themselves — people, agents, circles, goals, money, and rules — in a precise language (**maru**), and then *runs* on that description: funds flow to goals, agents act under mandates, every cent is recorded with its provenance, and all of it is visible.

This folder is the complete MVP definition. It is written to be fed to AI coding agents one task at a time.

## Layout

| Path | What it is |
|---|---|
| `PRD.md` | Product scope, users, the core loop, non-goals, glossary |
| `ARCHITECTURE.md` | Stack, repo layout, contexts, data flow, decision records, NFRs |
| `CONVENTIONS.md` | TDD workflow, test tooling, code style, API conventions, definition of done |
| `AGENT_PROMPT.md` | The wrapper prompt to send with every task |
| `specs/SPEC-01-language.md` | maru-lang v0: grammar, semantics, checks, IR, charter, diff |
| `specs/SPEC-02-domain.md` | Orgs, principals, spec versions, decisions, goals, tasks, evidence |
| `specs/SPEC-03-ledger.md` | Double-entry ledger (TigerBeetle-shaped), budgets, provenance |
| `specs/SPEC-04-authorization.md` | Cedar compilation, decisions, Biscuit mandate tokens |
| `specs/SPEC-05-payments.md` | Stripe Connect, donations, fees, refunds, reconciliation |
| `specs/SPEC-06-gateway-runtime.md` | Metered LLM gateway, hosted runtime (E2B), kill switch |
| `specs/SPEC-07-interfaces.md` | REST API, realtime channels, MCP tools, CLI commands |
| `specs/SPEC-08-web.md` | Screens, design tokens, UX rules |
| `specs/SPEC-09-security.md` | AuthN/Z, secrets, privacy, abuse, audit |
| `tasks/TASKS.md` | Task index, dependency graph, parallel waves, critical path |
| `tasks/*.md` | One self-contained task per file |

## How to run the build with agents

1. Work through `tasks/TASKS.md` wave by wave. Tasks in the same wave can run in parallel.
2. For each task, send the agent `AGENT_PROMPT.md` with the task file appended (or attached), plus access to the repo containing this `docs/` folder at `docs/mvp/`.
3. The agent writes **every listed test first**, commits them failing, then implements until green. Test IDs in the task file must appear in test names.
4. Review the PR against the task's acceptance criteria and `CONVENTIONS.md` → Definition of Done.
5. If an agent finds a spec contradiction, it stops and records it in `docs/mvp/OPEN_QUESTIONS.md` rather than guessing. Resolve, update the spec, and re-run.

## Source-of-truth order

When documents disagree: **SPEC files > task file > ARCHITECTURE > PRD**. Fix the losing document in the same PR that resolves the conflict.
