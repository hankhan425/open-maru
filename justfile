# openmaru task runner. Each stack recipe is a no-op until its manifest exists.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install toolchains' dependencies for whichever stacks exist.
setup:
    rustup show active-toolchain >/dev/null 2>&1 || echo "rustup not found; install from https://rustup.rs"
    if [ -f Cargo.toml ]; then cargo fetch; else echo "skip: no Cargo.toml"; fi
    if [ -f apps/server/mix.exs ]; then (cd apps/server && mix local.hex --force && mix local.rebar --force && mix deps.get); else echo "skip: no apps/server/mix.exs"; fi
    if [ -f web/package.json ]; then (cd web && pnpm install --frozen-lockfile); else echo "skip: no web/package.json"; fi

# All static checks (CONVENTIONS §3).
check: check-rust check-elixir check-web

check-rust:
    if [ -f Cargo.toml ]; then cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test --all; else echo "skip: no Cargo.toml"; fi

check-elixir:
    if [ -f apps/server/mix.exs ]; then cd apps/server && mix format --check-formatted && mix credo --strict && mix test && mix dialyzer; else echo "skip: no apps/server/mix.exs"; fi

check-web:
    if [ -f web/package.json ]; then cd web && pnpm lint && pnpm typecheck && pnpm test; else echo "skip: no web/package.json"; fi

# Run test suites only.
test:
    if [ -f Cargo.toml ]; then cargo test --all; else echo "skip: no Cargo.toml"; fi
    if [ -f apps/server/mix.exs ]; then (cd apps/server && mix test); else echo "skip: no apps/server/mix.exs"; fi
    if [ -f web/package.json ]; then (cd web && pnpm test); else echo "skip: no web/package.json"; fi

# Start Postgres and MinIO in the background.
services-up:
    docker compose up -d

services-down:
    docker compose down

# Repo-level checks and the T01 script tests.
check-repo:
    scripts/verify-layout
    scripts/verify-toolchain
    actionlint .github/workflows/*.yml
