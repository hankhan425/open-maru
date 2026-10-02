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
- **Status:** resolved
- **Conflict:** SPEC-07 §2 says every error uses the envelope with a stable code, but its table has no
  code for an unhandled server error (HTTP 500) and none for transport-level failures raised before a
  controller runs: 406 (no acceptable format), 413 (body too large), 415 (unsupported media type).
- **Options:** (a) add `internal_error` → 500 and reuse `invalid_request` for 406/413/415 while keeping
  the transport status; (b) add distinct codes (`not_acceptable`, `payload_too_large`,
  `unsupported_media_type`); (c) coerce these to 400/500 with existing codes.
- **Chosen (interim):** (a). `Openmaru.Error` knows `internal_error` (500); `OpenmaruWeb.ErrorJSON` maps
  401 → `unauthenticated`, 403 → `forbidden`, 404 → `not_found`, 422 → `validation_failed`,
  429 → `rate_limited`, other 4xx → `invalid_request`, 5xx → `internal_error`, keeping the HTTP status.
- **Resolution:** (b) (user, 2026-10-02). The interim choice broke the rule OQ-5 relies on: the
  code determines the HTTP status (`Openmaru.Error.status/1`), yet a 413 went out as
  `invalid_request`, which the table maps to 400. Every status the stack raises outside a
  controller now has a code with that status: `not_acceptable` (406), `request_timeout` (408,
  Bandit's body read timeout), `conflict` (409, an unhandled `Ecto.StaleEntryError`),
  `payload_too_large` (413), `uri_too_long` (414, Plug's query-string limit),
  `unsupported_media_type` (415), `internal_error` (500) and `service_unavailable` (503, the dev
  repo check). 400, 401, 403, 404, 422 and 429 keep their generic codes. SPEC-07 §2 lists the new
  codes and states the rule. Tests (T02-T02): a 406 and a 413 through the endpoint, and a guard
  that every status an exception from Plug, Phoenix, Bandit, Ecto or Postgrex carries renders a
  code whose status is that status.

### OQ-2: Money source text in the AST vs. AST equality in L02
- **Task:** L01
- **Status:** resolved
- **Conflict:** L01 (Deliverables) requires money literals to keep their source text, so
  `usd 12000` and `usd 12_000` give different ASTs. L02-T02 calls `lumen.messy.maru` (with
  `usd 12000`) "same AST as lumen", and L02-T10 compares `parse(format(x))` with `parse(x)`
  "ignoring spans and trivia"; formatting changes that text.
- **Options:** (a) treat `Money.text` as trivia in L02's comparisons; (b) drop the text from
  the AST and keep only micros; (c) normalize the text in the parser.
- **Chosen (interim):** (a). `ast::Money` has `text` (as written) and exact `micros`; L02
  compares with spans, comments and `Money.text` removed. Integers and metric values
  (`Int`, `Signed`) store digits without `_`, so they already compare equal.
- **Resolution:** (b). SPEC-01 §7 defines AST preservation as equality "ignoring spans and
  comments", and SPEC outranks the task file. Nothing downstream needs the text: the formatter
  prints canonical money from micros, the charter, IR, rule ids and diff use micros, and
  messages can quote the source at the span. `ast::Money` is now `{micros, span}`, so L02
  compares ASTs ignoring only spans and comments. The L01 task's deliverable line is updated.

### OQ-3: Lexical cases SPEC-01 §2/§5 do not assign a code to
- **Task:** L01
- **Status:** resolved
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
- **Resolution:** Interim choices kept, and written into the SPEC-01 §5 table (E101, E102,
  E103, E104 descriptions widened; E310 and E311 marked as reported by the parser). SPEC-01 §5
  now also says parse errors stop semantic checks, so the item the parser drops for E310 (or
  any other error) cannot lead to a second diagnostic such as E304 or W404 (L03-T31).

### OQ-4: Upper limits for whole numbers, durations and the derived monthly limit
- **Task:** L01
- **Status:** resolved
- **Conflict:** SPEC-01 caps money at 2^53 − 1 micros (§4.8) but gives no maximum for `INT`
  (seats, sponsors, approval counts, thresholds) or `DURATION`. Values the parser could store
  still break later layers: SPEC-02 §4.1 sets `deadline_at = now + within.secs`, which passes
  year 9999 (Elixir's `DateTime` limit) for `within 10000y`; a `term` of 69y or more
  overflows a Postgres `integer` (SPEC-02 §2 did not give `term_secs` a type); counts above
  2^53 lose precision when the web reads the IR in JS, and above 2^31 − 1 they overflow an
  `integer` column. Separately, §6.1's `unapproved_monthly_max_micros` multiplies day limits
  by 31 and sums every line, so one `usd 300_000_000 / day` line passes the 2^53 − 1 bound
  that §6 sets for IR money, and 66 maximal lines overflow `u64`.
- **Options:** (a) parser limits chosen from where the values are stored, reported as
  E103/E104 like money's E310; (b) checker range errors with new codes; (c) no limits and
  `bigint` or overflow checks in every consumer.
- **Chosen (interim):** (a). `INT` ≤ 2_147_483_647 (`ast::MAX_INT`, E103) and durations
  ≤ 100 years = 3_153_600_000 s (`ast::MAX_DURATION_SECS`, E104; `100y`, `36500d`, `5214w`
  pass, `101y`, `5215w` fail). SPEC-02 `circles.term_secs` is `bigint`, since 100y exceeds
  `integer`. Metric values (`SIGNED`) stay unlimited digit strings.
- **Resolution:** (a), with the interim values, in SPEC-01 §2 and §4.8. One 100-year cap
  for every duration: it is far below the technical ceiling (Elixir's year 9999, about 7,970
  years from 2026) and far above realistic terms and timeouts. A shorter cap for `within`
  alone is possible later if long-pending expense claims holding funds (SPEC-04 §5.2) become
  a problem. The derived monthly limit is summed exactly; over the money maximum the checker
  reports the new E318 on the goal (SPEC-01 §5, §6.1; L03-T32), rather than saturating, which
  would understate the bound the charter states.

### OQ-5: Status of the "handle already set" error
- **Task:** C01
- **Status:** resolved
- **Conflict:** C01-T11 expects "422 `invalid_request` (`handle_immutable` in details)". SPEC-07 §2
  maps `invalid_request` to 400 and gives 422 to `validation_failed`, and `Openmaru.Error.status/1`
  derives the HTTP status from the code everywhere.
- **Options:** (a) keep the code, answer 400 `invalid_request` with
  `details.reason: "handle_immutable"`; (b) keep the status, answer 422 `validation_failed` with
  the reason in `details`; (c) answer 422 with `invalid_request`, breaking the code-to-status
  table.
- **Chosen (interim):** (a). Clients switch on codes (CONVENTIONS §4), so the test keeps the code
  and the `handle_immutable` detail and asserts 400. An invalid or reserved handle stays 422
  `validation_failed` (C01-T10).
- **Resolution:** (b). Neither `invalid_request` nor `validation_failed` is specific to this
  case, so in either option clients switch on `details.reason`; the choice is which class the
  error belongs to. It is a well-formed request refused by a rule, like the other handle errors
  of the same `PATCH /me` (C01-T10, 422) and like C04's no-op proposal ("422 with
  `details.reason = "no_changes"`"). The answer is 422 `validation_failed` with
  `details.reason: "handle_immutable"` and `details.fields.handle`, so the handle picker
  (F01-T07) shows it inline like any other handle error. A new 409 code was rejected: it would
  add a stable code for an error the UI cannot produce (the picker shows only while the handle
  is unset). SPEC-07 §2 now states which class to use (400 malformed, 422 refused by a rule,
  409 conflict with another resource), and C01-T11 is updated.

### OQ-6: When the audit log hashes client IPs
- **Task:** C01
- **Status:** resolved
- **Conflict:** SPEC-09 §7 records the "IP (hashed after 30 days)", which means keeping the raw
  address for 30 days and rewriting the row later. C01 makes `audit_log` append-only with a
  trigger that rejects `UPDATE` (C01-T18), and C01-T18 expects sign-in rows "written with hashed
  IP".
- **Options:** (a) hash at write time; (b) keep raw IPs in a separate, mutable table that a job
  deletes after 30 days, referenced from the audit row; (c) let the trigger allow one `UPDATE`
  that only replaces the IP with its hash.
- **Chosen (interim):** (a). `audit_log.ip_hash` holds HMAC-SHA-256 of the address under a server
  key (`Openmaru.Audit.hash_ip/1`; derived from `SECRET_KEY_BASE` in production), so equal
  addresses still correlate and the IPv4 space cannot be brute-forced without the key. No raw IP
  is stored, which is stricter than SPEC-09 §7; abuse handling within 30 days works on the
  hashes.
- **Resolution:** (a), with a dedicated key. Raw IPs cannot sit in an append-only table and
  still be removed with the rest of a deleted account's PII (SPEC-09 §4), and raw addresses
  for incident response belong in load-balancer logs with their own retention. Hashing at
  write time is stricter than §7 only for the first 30 days: IPv4 has 2^32 addresses, so the
  key holder can reverse any hash by trying them all, for as long as the key exists. The key
  is therefore its own secret (`AUDIT_IP_HASH_KEY`, required in production, at least 32
  bytes) rather than derived from `SECRET_KEY_BASE`, so rotating that secret leaves hashes
  comparable; each row records `ip_hash_key_id` (a fingerprint of the key), so hashes from
  different keys are told apart after a rotation. Rotating the key and destroying old ones
  would make old hashes unlinkable, if the 30-day intent needs that later. SPEC-09 §7 and
  SPEC-02 §2 are updated. The address hashed is the client's as resolved by trusted-proxy
  handling (SPEC-09 §6), not the load balancer's.
- **Revised (user, 2026-10-02):** with one long-lived key, every IPv4 hash stayed reversible by the
  key holder for as long as the key existed, and the append-only table never drops rows, so the
  30-day intent of SPEC-09 §7 had become "kept forever". Hashed IPs are still personal data while
  they can be reversed, and data protection law expects such data to have a retention limit.
  Now each UTC day has its own random key, stored in `audit_ip_hash_keys` sealed under
  `AUDIT_IP_HASH_KEY`. An hourly job (`Openmaru.Audit.IpKeySweeper`) destroys a key 30 days after
  its day ends, so an address can be linked to its hashes for at most 31 days. `ip_hash_key_id`
  is now the id of the day's key row, and `Openmaru.Audit.hashes_for_ip/1` finds an address
  across the live days. Rotating `AUDIT_IP_HASH_KEY` makes all earlier hashes unlinkable at once.
  Equal addresses still correlate directly within one day. SPEC-09 §7, SPEC-02 §2 and H02's
  runbook deliverable are updated. Tests (C01-T18): per-day keys, destruction at the boundary,
  the sweeper, lookup across days, keys bound to their day, the table constraint, and rotation.

### OQ-7: A deleted user's handle
- **Task:** C01 (found while fixing handle rules; H02 implements deletion)
- **Status:** resolved
- **Conflict:** SPEC-09 §4 removes PII on account deletion and renames the *display name* to
  `deleted-user-<n>`; "ledger, votes, and activity remain with the pseudonymous handle". H02-T08
  instead says the *handle* becomes `deleted-user-<n>`. C01 makes handles immutable once set.
- **Options:** (a) keep the handle, rename the display name (SPEC-09 §4); (b) rename the handle
  (H02-T08), the one exception to immutability.
- **Chosen (interim):** none needed yet (C01 has no deletion). C01 reserves the
  `deleted-user-` prefix either way, so no live user can take a name that looks like a deleted
  account, and (b) can never collide with a taken handle.
- **Notes for the decision:** SPEC outranks the task file, which points to (a). Under (b) the old
  handle still appears in every stored spec version's `source_text` and charter (immutable
  history), so renaming does not remove it; and an active spec naming `@old` would fail E501 on
  the next amendment. Under (a) a handle that is a real name stays public after deletion.
- **Resolution:** (a). The handle is kept and stays taken, so nobody can sign up with it and
  inherit the deleted user's specs, votes, mentions and links; it also stays in immutable spec
  history either way. Deletion clears the display name (instead of renaming it
  `deleted-user-<n>`) and sets a new `users.deleted_at`; the API and the web show the account as
  deleted. A handle that is a real name stays public: if an erasure request ever requires
  removing it, that is a separate path after the MVP. SPEC-09 §4, SPEC-02 §2 and H02-T08 are
  updated. C01's `deleted-user-` prefix reservation stays, so no live handle reads as a deleted
  account.

### OQ-8: The email field on the sign-in card
- **Task:** C01 (affects F01)
- **Status:** resolved
- **Conflict:** SPEC-08 §3 and F01 describe the sign-in card as "Email + passkey, GitHub,
  Google". C01 never takes an email: passkey registration is anonymous, passkey sign-in uses
  discoverable credentials (the passkey names the user), and an email is stored only when an
  OAuth provider has verified it (SPEC-09 §1). There is no mailer or email verification in the
  MVP.
- **Options:** (a) keep the field only as the WebAuthn autofill hook
  (`autocomplete="username webauthn"`, conditional mediation), sending nothing to the server;
  (b) drop the field; (c) add email sign-up with verification (a mailer, a new flow; outside
  the MVP).
- **Chosen (interim):** C01's API takes no email. F01 decides between (a) and (b); (a) keeps the
  prototype's layout.
- **Resolution:** (b) for the MVP. The sign-in card offers a passkey, GitHub and Google; email
  sign-up (c) can be added after the MVP as its own task. Without the field there is no passkey
  autofill (conditional mediation); the passkey button opens the browser's passkey picker.
  SPEC-08 §3 and F01 are updated.
- **Follow-up (user, 2026-10-02):** with no email there is no account recovery: a user with one
  passkey who loses it loses the account, and the handle stays taken (OQ-7). That is acceptable
  while the MVP is not released; a recovery path (email sign-up, or another) is needed before any
  public release. F01 already offers a second passkey or a linked provider. Testing as several
  personas (founder, holder, member, operator, agent, donor, visitor) without a passkey or provider
  account each is planned in H01, not earlier: its e2e-only sign-in is also compiled into dev
  builds, with a persona seed, a dev-only persona switcher and a token task for the CLI and MCP
  (H01-T12).

### OQ-9: Leading zeros in metric values and the spec hash
- **Task:** L02
- **Status:** resolved
- **Conflict:** SPEC-01 §1 says formatting-only edits never change the spec hash, and §7 requires
  the formatter to preserve the AST. L01's AST keeps a metric value's digits as text
  (`ast::Signed`, because the IR keeps metric values as strings, §4.8), so
  `success: metric(m) >= 010` and `>= 10` are different ASTs. The formatter can only keep them
  apart (`010` stays `010`, `12.50` stays `12.50`), which gives them different spec hashes,
  although a reader would call the edit formatting-only. Counts and money have no such
  issue: their values are numbers and the formatter normalizes them (`007` → `7`).
- **Options:** (a) keep metric digits as written (a hash change for `010` → `10` is accepted);
  (b) normalize in the parser: strip leading zeros of the integer part (keeping one digit) and,
  optionally, trailing zeros of the fraction, so the AST, IR and formatter agree on one
  spelling; (c) keep (a) and have the checker warn about leading zeros.
- **Chosen (interim):** (a). L02 keeps metric digits apart from `_` grouping (SPEC-01 §7) and
  `l02_metric_values_keep_their_digits` pins it. Option (b) is an L01 parser change plus an L02
  test update.
- **Resolution:** (b), leading zeros only: the parser drops leading zeros from a metric
  value's integer part, keeping one digit (`ast::Signed::int`), so `010` and `10` parse,
  format and hash the same. Fraction digits stay as written (`12.50` ≠ `12.5`). SPEC-01 §2,
  §4.8 and §7 are updated; tests `l01_metric_values_drop_leading_zeros` and
  `l02_metric_values_drop_leading_zeros`.

### OQ-10: No code for `seats: 0` and `invite(sponsors: 0)`
- **Task:** L03
- **Status:** resolved
- **Conflict:** SPEC-01 §4.2 says `seats` is "required, ≥ 1" and §4.1 says `invite(sponsors: N)`
  needs "N ≥ 1", but the §5 table has no code for either. The parser accepts `0` (it bounds
  counts only from above, E103), so without a check `seats: 0` passes when the circle has no
  holders and is not referenced, and `sponsors: 0` reaches the IR, where C03's sponsoring
  would let anyone join with no sponsor (the same as `open()`, written differently).
- **Options:** (a) a new code, E324 "`seats` or `sponsors` is 0", like E309 (money) and E319
  (durations) for their types; (b) widen E307 ("approve count < 1 or > seats") to every count
  that must be ≥ 1; (c) have the parser reject `0` in these two positions as E103; (d) accept
  `0` (seats 0 then fails only through E306/E307/E317, sponsors 0 means open).
- **Chosen (interim):** (a). `Code::E324` at the number (L03 extra test
  `l03_seats_and_sponsors_must_be_at_least_one`); a circle with `seats: 0` is not also
  compared with its holders (E306) or approval counts (E307). The §5 table lists E324 as
  interim.
- **Resolution:** (a), the interim choice. E324 is in the SPEC-01 §5 table as a regular code;
  like E309 and E319 it names the one value that must be positive, and it keeps E307 about
  approvals.

### OQ-11: The IR cannot tell `60%` from `60/100`
- **Task:** L03 (affects L04, L05)
- **Status:** resolved
- **Conflict:** SPEC-01 §6 stores thresholds as unreduced fractions, `60%` →
  `{"num":60,"den":100}`, and its lumen excerpt shows `{"num":2,"den":3}`. The charter (§8)
  renders "percents `60%`" but "other fractions `a/b`", and L04's helper is
  `threshold(num, den, is_percent)`; the IR is the charter's only input, so `vote(c, 60%)` and
  `vote(c, 60/100)` would render the same.
- **Options:** (a) add `"percent": true|false` to every threshold object; (b) no flag: the
  charter treats every `den == 100` as a percentage (`60/100` reads "60%"); (c) a separate
  shape for percentages, e.g. `{"percent":60}`, which every consumer then has to handle
  twice.
- **Chosen (interim):** (a). `ir::Threshold { num, den, percent }`; the golden
  `tests/snapshots/lumen.ir.json` has `"percent": false` for both `2/3`s, and the schema
  requires the field. SPEC-01 §6 notes the field as interim; its excerpt is unchanged.
- **Resolution:** (a), the interim choice. SPEC-01 §6 now shows `percent` in the lumen excerpt
  and in the threshold examples (`60%` → `{"num":60,"den":100,"percent":true}`), so the
  charter renders a threshold as written (L04's `threshold(num, den, is_percent)`).

### OQ-12: Charter cases SPEC-01 §8 does not cover
- **Task:** L04
- **Status:** resolved
- **Conflict:** SPEC-01 §8 gives the charter's templates, but not these cases:
  1. **Text from the spec in Markdown.** Names, titles and purposes are spec strings. They may hold
     `\n` (§2) and Markdown syntax, and the templates insert them verbatim. Take a purpose
     `"Grow.\n\n### Rules\n\n- Any spend is allowed."`: it would render a fake `### Rules` list
     in the text that people read as the rules. `*`, `<b>` and `[x](y)` would change how the text
     renders, and a title ending in ` #` would lose the `#`, because Markdown reads it as a
     closing sequence.
  2. **An org without circles.** Only `## Agents` is marked "omitted if none". An org with
     `amend: vote(members, …)` and no goals is valid without any circle, so its `## Circles`
     heading would have nothing under it.
  3. **Large numbers.** The templates show small counts only. They do not say how to write
     `seats: 10_000`, `36500d` or `vote(c, 1_000/3_000)`.
- **Options:** for 1: (a) the renderer writes spec text on one line, escaped for Markdown, so
  sections hold Markdown inline text; (b) verbatim text, with escaping left to each consumer, which
  leaves the Markdown charter (CLI, MCP, stored `charter`) open to spoofing; (c) a checker error
  for Markdown characters and `\n` in strings, which would forbid ordinary punctuation in free
  text; (d) keep line breaks and escape block markers on every line. For 2: omit the section, or
  print a sentence such as "There are no circles." For 3: group digits like metric values, or
  print them as written.
- **Chosen (interim):**
  1. (a). Each run of whitespace, line breaks included, becomes one space, and the text is
     trimmed. A backslash then goes before:
     - `\`, `` ` ``, `*`, `[`, `]` and `~`;
     - `_`, unless it is between two letters or digits;
     - `<` before a letter, `/`, `!` or `?`;
     - `&` when it starts an entity (`&amp;`, `&#35;`);
     - at the start of the text, a block marker: `#`; `>`; `-` before a space, `-` or the end;
       `+` before a space or the end; the `.` or `)` after 1–9 leading digits, before a space or
       the end;
     - the first `#` of a closing run (`#`s at the end that follow a space).

     The rule applies to every string taken from the IR. It leaves ids, handles and metric names
     unchanged, except an `_` that is not between letters or digits (`a_`), and it does not
     change lumen's golden charter. A purpose that is empty after trimming gets no paragraph. An
     empty heading is a bare `#`. Tests: `l04_text_from_the_spec_is_escaped`,
     `l04_headings_and_empty_texts`, `l04_text_from_the_spec_cannot_change_the_structure`
     (proptest over generated IRs).
  2. Omit `## Circles` when there are none, as with `## Agents` (L04-T17).
  3. Every number in the text uses thousands separators, as metric values already do: counts,
     vacancies, duration counts and the parts of a fraction threshold (`10,000 seats`,
     `36,500 days`, `1,000/3,000`). Percentages are at most 100. Test:
     `l04_large_numbers_are_grouped`.

  SPEC-01 §8 records these choices, marked interim.
- **Resolution:** All three interim choices are kept. SPEC-01 §8 now states them as regular rules,
  without the interim markers:
  1. Spec text is written on one line, Markdown-escaped, in both the Markdown and the structured
     form. It renders literally, so the charter's structure comes only from the templates.
  2. `## Circles` is omitted when the org has none.
  3. Every number in the text is grouped by thousands.
- **Follow-up (user, 2026-10-02):** the escaping is written for CommonMark, but nothing said
  which renderer the web uses. A GFM renderer with autolinks (`marked`'s default) would turn a
  bare `https://…` or `www.…` in a purpose into a link, which §8 says spec text cannot add.
  SPEC-08 §4 now pins the web's renderer: one `MarkdownInline` component, CommonMark inline content
  only, raw HTML off, no GFM extensions, no typographer (F01-T15). SPEC-01 §8 names the assumption,
  and F03, F04, F05 and F06 render charter strings through the component.

### OQ-13: Policy ids can collide (`self:<handle>` and the rules of a goal named `self`)
- **Task:** L06
- **Status:** resolved
- **Conflict:** SPEC-04 §2.1 names a person's token policy `self:<handle>` and an approval rule's
  policy by its rule id, `<goal>:r_<8 hex>` (SPEC-01 §4.6). `self` is not a keyword, and
  `r_1a2b3c4d` is a valid handle, so a spec with `goal self` and a mandate for `@r_<hash of one of
  its rules>` checks clean but gives two policies the same id. The hash is known before the
  mandate is written, so anyone can write such a spec. Cedar needs unique ids. The other
  prefixes cannot collide: `steward`, `mandate` and `operator` are keywords, and
  `steward-session` has a `-`, which identifiers cannot contain.
- **Options:** (a) `compile` returns `CompileError::DuplicatePolicyId`, so the server must
  refuse such a spec when it compiles a proposal; (b) rename the token policy, e.g.
  `self:person:<handle>` (two colons, so no rule id can match); (c) prefix rule policies, e.g.
  `rule:<rule id>`; (d) reserve `self` as a keyword (SPEC-01 §2, a checker change).
- **Chosen (interim):** (a), keeping the SPEC-04 §2.1 names. Test:
  `l06_colliding_policy_ids_do_not_compile`.
- **Resolution:** (b), with the name `self-token:<handle>` (user, 2026-10-02). Goal ids cannot
  contain `-`, so no rule id can equal it, and no other prefix starts with `self-token:`; the
  collision is gone instead of being an error the server has to catch. SPEC-04 §2.1 and the lumen
  golden (`tests/snapshots/lumen.cedar`) use the new name. `CompileError::DuplicatePolicyId`
  stays for IRs the checker never emits, such as two goals with one id. Tests:
  `l06_a_goal_named_self_and_a_rule_like_handle_do_not_collide`,
  `l06_duplicate_policy_ids_do_not_compile`.

### OQ-14: Deny reason when the resource is not in the spec
- **Task:** L06
- **Status:** resolved
- **Conflict:** SPEC-04 §3 step 4 lists, for `Spend`, "no mandate → `NoMandate`" first, and a
  principal has no mandate in a goal the spec does not have. L06-T18 expects `Forbidden` for
  "unknown goal resource". The list also does not say what an action on the wrong kind of
  resource gets (`Spend` on an agent, `IssueToken` on a goal).
- **Options:** (a) before step 4's list, a resource that is not a goal of the spec (for the goal
  actions), not an agent of the spec (`StartSession`, and `IssueToken` on an agent), or of the
  wrong kind gives `Forbidden`; persons are open-world, so `IssueToken` on any person continues
  to the list (`NotOperator` unless the person's own token policy allows it); (b) `NoMandate`/`NotSteward`/`NotOperator`
  for unknown resources too, which contradicts L06-T18.
- **Chosen (interim):** (a), as L06-T18 expects; SPEC-04 §3 step 4 now says so. Tests: L06-T18,
  `l06_unknown_resources_and_mismatched_kinds_are_forbidden`.
- **Resolution:** (a), the interim choice (user, 2026-10-02). SPEC-04 §3 step 4 states it as a
  regular rule.

### OQ-15: Two rules in one goal can share a rule id
- **Task:** L06
- **Status:** resolved
- **Conflict:** SPEC-01 §4.6 makes a rule id `<goal>:r_` plus the first 8 hex characters (32 bits)
  of the SHA-256 of the canonical rule line, and E314 rejects only two rules with the same
  subject. Rules with different subjects can still get the same id, and a pair takes a birthday
  search of about 2^16 lines: `rule spend > usd 14_097 requires approve(core, 1)` and
  `rule spend > usd 104_588 requires approve(core, 1)` both get `g:r_239bc3bc`, and the spec
  checks clean. Rule ids are how approvals are tracked (`approved_rules`, `decisions.rule_id`,
  SPEC-04 §5.2), so approving one rule would count for the other. L06's `compile` refuses the IR
  (`CompileError::DuplicatePolicyId`), so such a spec cannot be activated, but the failure shows
  up only when the server compiles it, not in `check` or the editor.
- **Options:** (a) a checker error for two rules of a goal with the same id (a new code),
  reported at the second rule; (b) longer ids, e.g. 16 hex characters (64 bits, about 2^32 work
  for a pair), which changes every rule id, the IR golden and `decide.json`; (c) both; (d) leave
  it to `compile` (today).
- **Chosen (interim):** (d). Test: `l06_rules_with_colliding_ids_do_not_compile`.
- **Resolution:** (a) (user, 2026-10-02). The checker reports a new error, E325, at the second
  of two rules of a goal with the same id (span on the whole rule, a note on the first). A rule
  that already repeats a subject (E314) is not also E325. Ids keep their length, so every rule id,
  the IR golden and `decide.json` stay the same. A spec that collides is now rejected by `check`
  and the editor, and within a goal an approval names exactly one rule. SPEC-01 §4.6 and §5 and
  SPEC-04 §2.1 state it. `compile` still refuses an IR with equal ids
  (`CompileError::DuplicatePolicyId`), which the checker no longer emits. Tests: L03-T33
  (`l03_t33_rules_with_one_id_in_a_goal_is_e325`), `l06_rules_with_colliding_ids_do_not_compile`
  (now on an IR edited after checking).
