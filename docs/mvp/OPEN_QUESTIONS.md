# Open questions

Record spec contradictions and unresolved decisions here instead of guessing. Resolve, update the
relevant SPEC, then mark the entry resolved. Source-of-truth order: SPEC files > task file >
ARCHITECTURE > PRD.

## Entry format

```
### OQ-<n>: <short title>
- **Task:** <task id that surfaced it>
- **Status:** open | resolved
- **Conflict:** <what documents/tests disagree, with file + section references>
- **Options:** <choices considered>
- **Chosen (interim):** <what the implementation does meanwhile>
- **Resolution:** <filled in when resolved; link the SPEC change>
```

## Entries

### OQ-1: Envelope code for unhandled errors and transport-level 4xx
- **Task:** T02
- **Status:** open
- **Conflict:** SPEC-07 §2 says every error uses the envelope with a stable code, but its table has no
  code for an unhandled server error (HTTP 500) and none for transport-level failures raised before a
  controller runs: 406 (no acceptable format), 413 (body too large), 415 (unsupported media type).
- **Options:** (a) add `internal_error` → 500 and reuse `invalid_request` for 406/413/415 while keeping
  the transport status; (b) add distinct codes (`not_acceptable`, `payload_too_large`,
  `unsupported_media_type`); (c) coerce these to 400/500 with existing codes.
- **Chosen (interim):** (a). `Openmaru.Error` knows `internal_error` (500); `OpenmaruWeb.ErrorJSON` maps
  401 → `unauthenticated`, 403 → `forbidden`, 404 → `not_found`, 422 → `validation_failed`,
  429 → `rate_limited`, other 4xx → `invalid_request`, 5xx → `internal_error`, keeping the HTTP status.
- **Resolution:**
