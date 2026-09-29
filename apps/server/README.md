# openmaru server

Phoenix API-only app (`:openmaru`). See `docs/mvp/ARCHITECTURE.md` §2 and §4.

```
mix setup          # deps, create + migrate the database
mix phx.server     # http://localhost:4000/healthz
mix test
```

Checks (CONVENTIONS §3): `mix format --check-formatted && mix credo --strict && mix test && mix dialyzer`.
