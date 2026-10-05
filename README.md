# openmaru

**Collaborate on ambitious projects with organizations written in a precise, enforceable language.**

An organization on openmaru describes itself in **maru**: its people, AI agents, circles, goals, money and rules. openmaru then runs on that description. Funds flow to goals, agents act only under explicit mandates, decisions follow the org's own rules, and every cent is posted to a public ledger that shows how it is known.

> **Status:** early development. The MVP is being built task by task from the specs in [`docs/mvp/`](docs/mvp/README.md). Nothing is deployed yet.

## An org in maru

```maru
org "Lumen Studio" {
  purpose "Build and maintain an open, browser-based image editor."
  members: invite(sponsors: 1)
  amend: vote(core, 2/3) within 7d else deny

  circle core {
    seats: 3
    term: 1y
    holders: @mina, @jo
  }

  agent builder {
    operator: @mina
    runtime: hosted
  }

  goal editor "Open cloud image editor" {
    steward: core
    fund: usd 12_000 / month from treasury

    mandate builder {
      spend llm <= usd 4_000 / month
      per_request <= usd 25
      can: claim_tasks, post_evidence
    }

    rule spend > usd 500 requires approve(core, 1) within 48h else deny
  }
}
```

The toolchain checks this spec and renders it as a plain-English charter. It also works out its limits ("without any approval, at most $4,000 per month can be spent on this goal") and compiles it to [Cedar](https://www.cedarpolicy.com/) policies that decide every action. Every construct is enforced; none of it is just for show. The full example is in [`docs/mvp/specs/examples/`](docs/mvp/specs/examples/).

## How it works

1. **Describe.** Write the org's spec. Each version is content-addressed, and changes go through the spec's own `amend` rule.
2. **Fund.** The org funds a goal from its treasury. Supporters can pledge to pay for accepted work, or donate up front within a cap.
3. **Mandate.** Governance gives a person or agent a mandate: what it may do and how much it may spend, carried as an attenuable, revocable [Biscuit](https://www.biscuitsec.org/) token.
4. **Work.** Agents claim tasks and call models through a metered gateway. Every call is authorized, held and posted to a double-entry ledger.
5. **Review.** Workers post evidence, and stewards accept the work. Pausing a goal stops all of its sessions and spending within seconds.
6. **Show.** Public goal pages show progress, evidence, and spend by provenance tier (*verified*, *evidenced* or *attested*). The ledger is hash-chained, with daily public checkpoints.

See the [PRD](docs/mvp/PRD.md) for scope and the glossary, and [ARCHITECTURE](docs/mvp/ARCHITECTURE.md) for the design.

## Repository layout

| Path | What it is |
|---|---|
| `crates/maru_core` | maru language: lexer, parser, formatter, checker, IR, charter, Cedar compiler |
| `crates/maru_cli` | `maru` command-line tool |
| `crates/maru_nif` | Rustler NIF exposing `maru_core` to the server |
| `crates/maru_wasm` | WASM build of `maru_core` for the browser |
| `crates/maru_token` | Mandate tokens |
| `apps/server` | Phoenix API: accounts, auth, ledger, audit |
| `web/` | Web app (scaffold) |
| `runtime/` | Hosted agent runtime (scaffold) |
| `docs/mvp/` | PRD, architecture, conventions, specs and task files |

## Development

You need Rust (stable, pinned by `rust-toolchain.toml`), the versions in `.tool-versions` (Erlang, Elixir, Node, pnpm), Docker and [just](https://github.com/casey/just).

```sh
just setup          # fetch dependencies for each stack
just services-up    # Postgres and MinIO via docker compose
just test           # run all test suites
just check          # formatting, linters, tests, dialyzer
```

To run the server:

```sh
cd apps/server
mix setup           # create and migrate the database
mix phx.server      # http://localhost:4000/healthz
```

## Contributing

Work follows the task files in [`docs/mvp/tasks/`](docs/mvp/tasks/TASKS.md). Write the task's tests first, then implement until they pass. See [CONVENTIONS](docs/mvp/CONVENTIONS.md) for the definition of done. If the specs contradict each other, record it in [OPEN_QUESTIONS](docs/mvp/OPEN_QUESTIONS.md) rather than guessing.
