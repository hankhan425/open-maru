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

### OQ-2: Money source text in the AST vs. AST equality in L02
- **Task:** L01
- **Status:** open
- **Conflict:** L01 (Deliverables) requires money literals to keep their source text, so
  `usd 12000` and `usd 12_000` give different ASTs. L02-T02 calls `lumen.messy.maru` (with
  `usd 12000`) "same AST as lumen", and L02-T10 compares `parse(format(x))` with `parse(x)`
  "ignoring spans and trivia"; formatting changes that text.
- **Options:** (a) treat `Money.text` as trivia in L02's comparisons; (b) drop the text from
  the AST and keep only micros; (c) normalize the text in the parser.
- **Chosen (interim):** (a). `ast::Money` has `text` (as written) and exact `micros`; L02
  compares with spans, comments and `Money.text` removed. Integers and metric values
  (`Int`, `Signed`) store digits without `_`, so they already compare equal.
- **Resolution:**

### OQ-3: Lexical cases SPEC-01 §2/§5 do not assign a code to
- **Task:** L01
- **Status:** open
- **Conflict:** SPEC-01 does not say which code covers: an unknown string escape (`\t`); an
  integer too large for 64 bits in a count position (`seats: 99999999999999999999999`); a
  money literal above 2^53 − 1 micros (E310 is listed with the checker's codes); a
  duration whose seconds overflow; an unterminated string that runs to end of file (E102
  and E202 would both apply).
- **Options:** assign codes per case, or add new codes.
- **Chosen (interim):** unknown escape → E101 at the escape; oversized integer → E103;
  money over the maximum → E310 from the parser (the item is dropped, so the checker never
  sees it and cannot report it twice); oversized duration → E104; E102 at end of file
  suppresses E202. No new codes.
- **Resolution:**
