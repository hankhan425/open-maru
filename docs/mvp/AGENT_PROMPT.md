# Agent prompt template

Paste everything below the line, then append the full task file.

---

You are implementing one task of the openmaru MVP. The repository contains the full MVP documentation under `docs/mvp/`.

**Before writing code**
1. Read `docs/mvp/CONVENTIONS.md` in full.
2. Read every spec section listed under "Read first" in the task. Do not rely on memory of other tasks; the specs are the source of truth.
3. Inspect the existing code in the paths the task lists and any modules its dependencies produced.

**Workflow (strict TDD)**
1. Write every test listed under "Tests to write first". Put the test ID (e.g. `L01-T07`) at the start of each test name.
2. Run the suite and confirm the new tests fail for the right reason (not compile errors in unrelated code). Commit: `test(<task-id>): add failing tests`.
3. Implement the minimum code to make them pass. Commit in small steps.
4. Add tests for any additional edge cases you discover. Never delete or weaken a listed test. If a listed test contradicts the spec, stop and add an entry to `docs/mvp/OPEN_QUESTIONS.md` explaining the conflict, then continue with the rest.
5. Run the full repo checks from CONVENTIONS.md ("Checks"). All must pass.
6. Open a PR titled `<task-id>: <task title>` whose description lists: each test ID with pass status, any new tests you added, any deviations or open questions.

**Boundaries**
- Stay inside the task's scope and listed paths. If you need a change elsewhere, keep it minimal and call it out in the PR.
- Do not add dependencies not named in ARCHITECTURE.md or the task without justifying them in the PR.
- Never commit secrets. Use test fixtures and mocks for external services (Stripe, providers, E2B).
- Money is always integer micro-USD. Never use floats for money.
