# W03 · OpenAI Chat Completions gateway

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Gateway | W02 | M | 11 |

**Read first:** SPEC-06 §3.1, §3.3–§3.5.
**Paths:** `lib/openmaru/gateway/openai.ex`, gateway controller routes

## Goal
OpenAI-compatible clients get the same metering, holds, and denials as Anthropic clients, reusing W02's pipeline.

## Deliverables
- Adapter implementing the provider callbacks introduced in W02 (`hold/2`, `prepare_upstream/2`, `usage_from_body/1`, `usage_tap/1`, `error_envelope/2`).
- `/gw/openai/v1/chat/completions`; the upstream is the goal's `openai_chat` endpoint (W01, SPEC-06 §2.1), priced with that endpoint's prices.
- `stream_options.include_usage` injection and conditional stripping of the usage-only chunk.

## Tests to write first
- [ ] **W03-T01** Non-stream: upstream gets `Authorization: Bearer <goal key>`; cost uses (prompt − cached)×input + cached×cache_read + completion×output; spend posted.
- [ ] **W03-T02** Hold uses `max_completion_tokens`, else `max_tokens`, else catalog max; `n: 3` multiplies output; `n: 5` → 400 `invalid_request`.
- [ ] **W03-T03** Streaming without client `include_usage`: upstream request has it; usage-only chunk not forwarded; `[DONE]` forwarded.
- [ ] **W03-T04** Streaming with client `include_usage: true`: usage chunk forwarded.
- [ ] **W03-T05** `web_search_options` → 400 `unsupported_feature` in OpenAI envelope.
- [ ] **W03-T06** Endpoints:
  - A goal that chose another listed `openai_chat` endpoint (fixture, Bypass) is routed there and priced with its prices; the spend posts `verified` with `meta.endpoint`.
  - The same model on the `openai` endpoint is priced differently.
  - A deactivated chosen endpoint → 424 `provider_credentials_missing` (`endpoint_inactive`) in the OpenAI envelope, with no upstream call.
- [ ] **W03-T07** Denials mapped with OpenAI envelope (`type: "openmaru_error"`, `code`) and SPEC-06 statuses.
- [ ] **W03-T08** Upstream error passthrough + void; stream without usage chunk → hold posted `estimated`.
- [ ] **W03-T09** Integration (`@tag :integration`): official `openai` Node SDK with `baseURL` streams and the spend posts.

## Out of scope
Responses API, embeddings, images, audio.
