# SPEC-01 — maru-lang v0

The maru language describes one organization: its membership, circles, agents, goals, mandates, rules, and how the description itself changes. It is **declarative, non-Turing-complete, total, and deterministic**. Every construct in v0 is enforced by the runtime (ADR-8).

Canonical example: `examples/lumen.maru`. Its golden charter: `examples/lumen.charter.md`.

## 1. Files

- One org per file, extension `.maru`, UTF-8, LF line endings (CRLF accepted, normalized by formatter).
- Maximum source size: 256 KiB (E109). The canonical formatted source (§7) must fit too.
- The **spec hash** is `sha256:` + lowercase hex SHA-256 of the canonical formatted source (§7). Formatting-only edits never change the hash.

## 2. Lexical structure

| Token | Pattern / rule |
|---|---|
| Comment | `#` to end of line. Preserved by the formatter. |
| Whitespace | Insignificant (spaces, tabs, newlines). The grammar is self-delimiting. |
| `IDENT` | `[a-z][a-z0-9_]*`, max 40 chars, not a keyword (E107) |
| `HANDLE` | `@[a-z0-9][a-z0-9_-]{1,29}` (E106). Refers to a platform user handle. |
| `STRING` | `"…"`, escapes `\"` `\\` `\n`, no raw newline (E108), max 500 chars after unescaping (E108) |
| `INT` | `[0-9]+` with optional single `_` between digit groups (`12_000`); no leading/trailing/double `_` (E103); as a count (seats, sponsors, approval count, threshold) at most 2_147_483_647 (E103) |
| `DECIMAL` | `INT "." [0-9]+` (money allows max 6 fractional digits — E311) |
| `SIGNED` | optional `-` then `INT` or `DECIMAL` (metric values only); leading zeros of the integer part are not significant (`010` = `10`) |
| `DURATION` | `INT` + unit `m` (minutes), `h`, `d`, `w` (7d), `y` (365d). Must be > 0 (E319) and at most 100 years (E104). (E104) |
| `DATE` | `YYYY-MM-DD`, valid Gregorian date, years 2000–2999 (E105) |
| `THRESHOLD` | `INT "/" INT` (fraction, 0 < a/b ≤ 1) or `INT "%"` (1–100) (E308) |
| Punctuation | `{ } ( ) : , / <= >= < > == ->` |

**Keywords (reserved):** `org purpose members open invite sponsors amend circle seats term holders agent operator runtime byo hosted goal steward fund from treasury once success metric by on_underfunded pause continue on_close return transfer mandate spend per_request can expires claim_tasks create_tasks post_evidence report_metric rule requires approve vote within else deny allow close usd llm compute expense day week month`

## 3. Grammar (EBNF)

```ebnf
file          = org_decl EOF ;
org_decl      = "org" STRING "{" { org_item } "}" ;
org_item      = "purpose" STRING
              | "members" ":" membership
              | "amend" ":" procedure [ timeout ]
              | circle | agent | goal ;
membership    = "open" "(" ")"
              | "invite" "(" "sponsors" ":" INT ")" ;

circle        = "circle" IDENT "{" { circle_item } "}" ;
circle_item   = "seats" ":" INT
              | "term" ":" DURATION
              | "holders" ":" HANDLE { "," HANDLE } ;

agent         = "agent" IDENT "{" { agent_item } "}" ;
agent_item    = "operator" ":" HANDLE
              | "runtime" ":" ( "byo" | "hosted" ) ;

goal          = "goal" IDENT STRING "{" { goal_item } "}" ;
goal_item     = "steward" ":" IDENT
              | "purpose" STRING
              | "fund" ":" money ( "/" period | "once" ) "from" "treasury"
              | "on_underfunded" ":" ( "pause" | "continue" )
              | "on_close" ":" ( "return" "treasury" | "transfer" IDENT )
              | "success" ":" "metric" "(" IDENT ")" cmp SIGNED [ "by" DATE ]
              | mandate
              | rule ;

mandate       = "mandate" ( IDENT | HANDLE ) "{" { mandate_item } "}" ;
mandate_item  = "spend" category "<=" money "/" period
              | "per_request" "<=" money
              | "can" ":" capability { "," capability }
              | "expires" ":" DATE ;
capability    = "claim_tasks" | "create_tasks" | "post_evidence"
              | "report_metric" "(" IDENT ")" ;

rule          = "rule" subject "requires" procedure [ timeout ] ;
subject       = "spend" [ category ] [ ">" money ]
              | "close" ;

procedure     = "approve" "(" IDENT "," INT ")"
              | "vote" "(" ( IDENT | "members" ) "," THRESHOLD ")" ;
timeout       = "within" DURATION "else" ( "deny" | "allow" ) ;

money         = "usd" ( INT | DECIMAL ) ;
category      = "llm" | "compute" | "expense" ;
period        = "day" | "week" | "month" ;
cmp           = ">=" | ">" | "<=" | "<" | "==" ;
```

Parsing is error-tolerant: on a syntax error inside a block, the parser skips to the next `}` or next item keyword at the same depth and continues, so one mistake yields one diagnostic, not a cascade.

## 4. Semantics

### 4.1 Org
- `purpose` optional.
- `members` default: `invite(sponsors: 1)`.
  - `open()`: any signed-in user may join.
  - `invite(sponsors: N)`: a user becomes a member once N distinct existing members sponsor them. N ≥ 1.
- `amend` **required** (E304). Governs every change to this spec. Default timeout `within 7d else deny`.
- Circle holders and agent operators are members implicitly. Anyone may leave, holders and operators included, which ends their seats and operator roles (SPEC-02 §3.6).

### 4.2 Circles
- `seats` required, ≥ 1. `holders` optional, ≤ seats (E306), no duplicates (E323).
- `term` optional. When present, a holder's powers lapse `term` after the spec version that first (continuously) listed them became active. Lapsed holders remain in the text but are not *effective holders*; reappointment is an amendment that removes and re-adds, or any amendment passed after the lapse that still lists them (which restarts their term). The runtime computes effective holders; the checker does not.

### 4.3 Agents
- `operator` required: the accountable human. `runtime` default `byo`.
- `hosted` means openmaru may start sessions for this agent on the hosted runtime (SPEC-06).

### 4.4 Goals
- Header: `goal <id> "<title>"`. `steward` required (a circle with ≥ 1 declared holder — E317).
- `fund` optional, at most one (E305).
  - `usd X / period from treasury`: at each UTC period start, allocate X from treasury to the goal (partial if the treasury is short).
  - `usd X once from treasury`: allocate X once, when the goal first becomes active.
  - No `fund`: goal is funded by earmarked donations only.
- `on_underfunded` default `pause`: if an allocation is short, the goal pauses (all mandates suspended) until topped up. `continue`: goal stays active with what it has.
- `on_close` default `return treasury`. `transfer <goal>`: remaining funds move to another goal of this org (not itself, E315).
- `success` optional: a metric name, comparator, target, optional deadline. Metric values are reported via API by stewards or principals holding `report_metric(<name>)`.

### 4.5 Mandates
- One mandate per principal per goal (E312). Principal is a declared agent (E303) or a `@handle`.
- `spend <category> <= money / period`: cumulative limit per UTC period. One line per category (E313).
  - `llm`: model calls through the gateway. `compute`: hosted runtime sessions. `expense`: expense claims.
- `per_request <= money`: optional cap on any single spend.
- `can`: capabilities (duplicates ignored with W408).
- `expires`: mandate invalid from `DATE`T00:00:00Z onward.
- A principal with no mandate in a goal has no powers there, except steward holders (SPEC-04 §2).

### 4.6 Rules (approval gates)
- `rule spend [category] [> money] requires P [timeout]`: any spend matching the category (or any category if omitted) and strictly over the amount (or any amount if omitted) must be approved by decision P before it executes.
- `rule close requires P [timeout]`: closing the goal requires decision P. Without such a rule, closing requires `approve(<steward>, 1)`.
- Default timeout: `within 7d else deny`.
- Rule identity: `"<goal_id>:r_" + first 8 hex chars of SHA-256(canonical rule text)` (canonical text = the formatted `rule …` line without indentation or comments; `maru_core::fmt::rule_line`). Two rules with the same subject in one goal → E314. Two rules of one goal whose ids are equal (different rule lines whose hashes start with the same 8 hex characters) → E325, so within a goal every rule has its own id and an approval of one rule never counts for another (OQ-15).

### 4.7 Decision procedures
- `approve(C, N)`: passes when N distinct effective holders of circle C approve. Fails early when rejections make N approvals impossible. `members` not allowed (E322). 1 ≤ N ≤ seats(C) (E307).
- `vote(C, T)`: eligible voters are the effective holders of C, snapshotted when the decision opens. Passes when yes votes ≥ ceil(T × eligible); a holder who doesn't vote counts against it. Fails early when no votes > eligible − required.
- `vote(members, T)`: eligible voters, snapshotted when the decision opens, are the members who joined at least 30 days earlier and are not silent or suspended (SPEC-02 §3.4). The vote counts only when at least 20% of them vote, yes or no; it then passes when yes votes ≥ ceil(T × votes cast). Members who don't vote don't count against it. It ends early only once the outcome can no longer change (SPEC-02 §4.2), and is otherwise decided at the deadline (OQ-16).
- Timeout: at deadline, an undecided procedure resolves to the `else` outcome. A member-wide vote that did not reach 20% turnout is undecided.
- 20% and 30 days are platform rules, not settings. Who counts as an effective holder, and what happens to a decision when people have left or gone silent, is SPEC-02 §3.4 and §4.1.

### 4.8 Money, time, periods
- Money is integer micro-USD. `usd 12.50` = 12_500_000. Max per literal 9_007_199_254_740_991 micros (E310). Must be > 0 (E309).
- Periods are UTC calendar periods: day; ISO week starting Monday 00:00; month starting on the 1st 00:00.
- Durations: `m`=60s, `h`=3600s, `d`=86400s, `w`=604800s, `y`=31536000s. At most 100 years = 3_153_600_000 s in any unit (`36500d` and `5214w` pass, `5215w` fails; E104), so every deadline and term end computed from a spec stays within the date range of Elixir, Postgres and JS.
- Counts (`seats`, `sponsors`, approval counts, threshold numbers) are at most 2_147_483_647 (E103), so they fit a Postgres `integer` and a JS number. Metric values have no limit (the IR keeps them as strings, without leading zeros in the integer part).

## 5. Static checks

The checker is pure: `check(source, opts) → {diagnostics, ir?}`. IR is returned only when there are no errors. `opts.now` (optional ISO timestamp) enables time-relative warnings; without it they are skipped so checking stays deterministic.

Checking has two stages. The parser reports E1xx, E2xx, E310 and E311. If it reports any error, `check` returns those diagnostics alone: no semantic checks run and there is no IR. The parser leaves an item with an error out of the tree, so checking that tree would report the same mistake again (a malformed `seats` would also be a missing one, E304). The first stage also formats the tree for the spec hash; when the formatted source would exceed 256 KiB, `check` returns that E109 alone. Semantic checks (the other E3xx codes and all W4xx) run only on a source that parses without errors.

Within the semantic stage, one mistake gives one diagnostic:
- A repeat is reported at its second occurrence, with a note giving the first one's position (e.g. `first declared at line 7, column 10`): E301, E305, E312, E313, E314, E323, E325, W408. The repeat is then ignored (a second `fund` is not compared with spend limits; a repeated `can` adds nothing).
- E305 covers every field that may appear once: `purpose`, `members` and `amend` in the org; `seats`, `term` and `holders`; `operator` and `runtime`; `steward`, `purpose`, `fund`, `on_underfunded`, `on_close` and `success` in a goal; `per_request`, `can` and `expires` in a mandate. Repeated `spend` lines are E313 (per category).
- A value that is already an error is not checked again for its consequences: no E306 for a circle whose `seats` is missing or 0; no E307 above the seats of such a circle; no E316 where E307 or E302 applies; no W403 for a zero `fund` or spend limit; an unknown steward is E302, not also E317; a rule that repeats a subject is E314, not also E325.
- Circles, agents and goals have separate id spaces (a circle and a goal may both be `core`). A reference to a repeated id resolves to its first declaration.

Spans: E301, E302, E303, E312, E315 and E317 point at the identifier or handle; E304 at the block's identifier (the org's name for `amend`); E305, E306, E313, E325, W403, W404 and W405 at the whole item; E307 at the count; E308 at the threshold; E309 at the amount (`usd …`); E314 at the second rule's subject; E316 at the procedure; E318 at the goal's id; E319 at the duration; E322 at `members`; E324 at the number; W401 at the date; W402 at `within … else allow`; W406 at the agent's id; W408 at the repeated capability. Diagnostics are sorted by span start; ties keep the order in which they were found.

| Code | Severity | Condition |
|---|---|---|
| E101 | error | Unexpected character, or unknown escape in a string (at the escape) |
| E102 | error | Unterminated string (one that runs to end of file is not also reported as E202) |
| E103 | error | Malformed number (underscores), or number too large |
| E104 | error | Malformed duration, or duration too long |
| E105 | error | Invalid date |
| E106 | error | Invalid handle |
| E107 | error | Invalid or reserved identifier |
| E108 | error | String contains raw newline or exceeds 500 chars |
| E109 | error | Source exceeds 256 KiB (the formatter also reports it when the formatted source would) |
| E201 | error | Expected X, found Y |
| E202 | error | Unexpected end of file |
| E203 | error | Content after the org block |
| E301 | error | Duplicate circle/agent/goal id |
| E302 | error | Unknown circle |
| E303 | error | Unknown agent |
| E304 | error | Missing required field (`amend`; circle `seats`; agent `operator`; goal `steward`) |
| E305 | error | Field given twice in one block |
| E306 | error | More holders than seats |
| E307 | error | approve count < 1 or > seats |
| E308 | error | Threshold out of range |
| E309 | error | Money must be > 0 |
| E310 | error | Money exceeds maximum (reported by the parser) |
| E311 | error | Money has more than 6 decimal places (reported by the parser) |
| E312 | error | Two mandates for the same principal in a goal |
| E313 | error | Two spend lines for the same category in a mandate |
| E314 | error | Two rules with the same subject in a goal |
| E315 | error | `on_close: transfer` targets itself or an unknown goal |
| E316 | error | Amendment deadlock: `amend` cannot be satisfied by declared holders (approve N > holders of C; vote on a circle with 0 holders) |
| E317 | error | Steward circle has no holders |
| E318 | error | A goal's `unapproved_monthly_max_micros` (§6.1) exceeds 9_007_199_254_740_991 micros |
| E319 | error | Duration must be > 0 |
| E322 | error | `approve(members, …)` is not allowed |
| E323 | error | Duplicate holder in a circle |
| E324 | error | `seats` or `invite(sponsors: …)` is 0 |
| E325 | error | Two rules in a goal have the same rule id (§4.6) |
| W401 | warning | Mandate `expires` is in the past: `opts.now` is at or after `DATE`T00:00:00Z (only with `opts.now`) |
| W402 | warning | `else allow` on a rule or `amend` |
| W403 | warning | A mandate's spend limit for a category exceeds the goal's `fund` normalized to the same period (both converted to a month with the §6.1 factors: `usd 50 / day` is 1,550 a month; a `once` fund never warns) |
| W404 | warning | `on_underfunded` given but the goal has no `fund` |
| W405 | warning | `per_request` exceeds every spend limit of the mandate, which has at least one (no effect) |
| W406 | warning | Agent declared but holds no mandate in any goal (once, at its first declaration) |
| W408 | warning | Duplicate capability |

Diagnostic shape (all targets):
```json
{"code":"E302","severity":"error","message":"unknown circle `cor`","span":{"start":{"line":14,"col":14,"offset":301},"end":{"line":14,"col":17,"offset":304}},"notes":["did you mean `core`?"]}
```
Lines and columns are 1-based; columns count Unicode scalar values. "Did you mean" suggestions use Levenshtein distance ≤ 2 (in Unicode scalar values) and name the closest declared id of the right kind, the first in source order on a tie: circles for E302 (plus `members` inside `vote(…)`), agents for E303, the org's other goals for E315. All lookups in one check share a work budget (`maru_core::suggest::Suggester::CHECK_BUDGET`, 4 million character comparisons); once it is spent, further unknown references get no suggestion. Only sources with thousands of unknown references and thousands of declared ids reach it, and the result stays deterministic.

## 6. IR (intermediate representation)

Stable JSON consumed by server, web, CLI. `ir_version: 1`. Arrays preserve source order. Money fields are integers (micros, ≤ 2^53−1). Excerpt for `lumen.maru`:

```json
{
  "ir_version": 1,
  "source_hash": "sha256:…",
  "org": {
    "name": "Lumen Studio",
    "purpose": "Build and maintain an open, browser-based image editor.",
    "membership": {"kind": "invite", "sponsors": 1},
    "amend": {"procedure": {"kind": "vote", "circle": "core", "threshold": {"num": 2, "den": 3, "percent": false}},
              "within": {"value": 7, "unit": "d", "secs": 604800}, "else": "deny"},
    "circles": [{"id": "core", "seats": 3, "term": {"value": 1, "unit": "y", "secs": 31536000}, "holders": ["mina", "jo"]}],
    "agents": [{"id": "builder", "operator": "mina", "runtime": "hosted"}],
    "goals": [{
      "id": "editor", "title": "Open cloud image editor",
      "purpose": "Ship a usable editor with layers, masks and export.",
      "steward": "core",
      "fund": {"amount_micros": 12000000000, "period": "month"},
      "on_underfunded": "pause",
      "on_close": {"kind": "return_treasury"},
      "success": {"metric": "weekly_active_users", "cmp": ">=", "value": "10000", "by": "2027-06-30"},
      "mandates": [{
        "principal": {"kind": "agent", "id": "builder"},
        "spend": [{"category": "llm", "limit_micros": 4000000000, "period": "month"},
                  {"category": "compute", "limit_micros": 1000000000, "period": "month"}],
        "per_request_micros": 25000000,
        "capabilities": ["claim_tasks", "post_evidence", "report_metric:weekly_active_users"],
        "expires": "2027-01-01"
      }, {
        "principal": {"kind": "person", "id": "jo"},
        "spend": [{"category": "expense", "limit_micros": 500000000, "period": "month"}],
        "per_request_micros": null,
        "capabilities": ["claim_tasks", "create_tasks", "post_evidence"],
        "expires": null
      }],
      "rules": [{"id": "editor:r_…", "subject": {"kind": "spend", "category": null, "over_micros": 500000000},
                 "procedure": {"kind": "approve", "circle": "core", "count": 1},
                 "within": {"value": 48, "unit": "h", "secs": 172800}, "else": "deny"}, "…"],
      "limits": {"unapproved_monthly_max_micros": 5000000000}
    }]
  }
}
```
Thresholds are stored as fractions with the form they were written in: `60%` → `{"num":60,"den":100,"percent":true}` (not reduced); `2/4` stays `{"num":2,"den":4,"percent":false}`, so the charter can say "60%" or "2/4" as written. Durations keep their source unit (`{"value":48,"unit":"h","secs":172800}`) so the charter can say "48 hours". `term` is `null` when absent. Defaults are materialized in the IR (never absent); the default timeout is `{"value":7,"unit":"d","secs":604800}`.

The full shape is `crates/maru_core/schema/ir.v1.json` (JSON Schema 2020-12; every field required, no other fields). Beyond the excerpt:
- Every field is always present. Optional values without a default are `null`: org and goal `purpose`, `term`, `fund`, `success`, `success.by`, `per_request_micros`, `expires`. Lists are `[]` when empty.
- `membership`: `{"kind":"open"}` or `{"kind":"invite","sponsors":N}`.
- `fund.period`: `"day"`, `"week"`, `"month"`, or `"once"` for `usd X once from treasury`.
- `on_close`: `{"kind":"return_treasury"}` or `{"kind":"transfer","goal":"<goal id>"}`.
- `success.value`: the metric target as a decimal string (`-` sign, no `_`, no leading zeros in the integer part, fraction digits as written; §4.8).
- Procedures: `{"kind":"approve","circle":C,"count":N}`; `{"kind":"vote","circle":C | null,"threshold":T}`, where `null` means all members.
- Rule subjects: `{"kind":"spend","category":"llm"|"compute"|"expense"|null,"over_micros":X|null}` or `{"kind":"close"}`.
- `capabilities`: `claim_tasks`, `create_tasks`, `post_evidence`, `report_metric:<name>`, in source order without repeats (W408).
- Handles (holders, operators, person principals) are written without `@`.

### 6.1 Limits analysis
For each goal, `unapproved_monthly_max_micros` is an upper bound on spend possible in one calendar month with no approvals:
- Sum over mandates and spend lines of `limit × factor(period)`, factor: month 1, week 6, day 31.
- Exclude a (mandate, category) line if some rule in the goal has subject `spend` covering that category (category matches or is omitted), **no** amount threshold, and `else deny`.
- Rules with thresholds or `else allow` do not exclude anything.
- Expired mandates are still counted (the analysis is time-independent).
- The sum is exact. If it exceeds the money maximum (§4.8), the checker reports E318 on the goal, so every money value in the IR stays ≤ 2^53−1 and the bound the charter states is never understated.

## 7. Formatter

- 2-space indentation; one item per line; lists on one line separated by `, `.
- Blank lines: exactly one blank line before and after every block item (`circle`, `agent`, `goal`, `mandate`), and one before the first `rule` that follows a non-rule item. Never a blank line at the start or end of an enclosing block, never two in a row, none elsewhere. The blank line goes above an item's leading comments, and comments before a block's `}` count as content that follows: a block item just before them is set off by a blank line. An empty block without comments is written `{}`.
- Item order is preserved (the formatter never reorders).
- Numeric literals (money, counts, metric values): the integer part is grouped with `_` by thousands **iff it has 4 or more digits** (`12000` → `12_000`, `4000` → `4_000`, `500` stays `500`, `1_0` → `10`). Money fractions: trailing zeros trimmed but at least 2 digits if any fraction remains (`12.5` → `12.50`, `3.000100` → `3.0001`, `7.00` → `7`). Threshold numbers are counts (`vote(core, 1_000/3_000)`). Metric values are grouped the same way and lose the leading zeros of their integer part, so `010` and `10` hash the same; their fraction digits stay as written, because the AST and IR keep metric values as text (`-1500.5` → `-1_500.5`, `-007.50` → `-7.50`, `12.50` stays). Durations and dates are not grouped; a duration is its count without leading zeros followed by its unit (`007d` → `7d`, `36_500d` → `36500d`).
- Spacing: `key: value`; `usd 12_000 / month`; `vote(core, 2/3)`; operators surrounded by single spaces.
- Comments: full-line comments stay attached above the following item at that item's indentation; trailing comments stay on their line after one space. A comment after `{` stays on that line; comments before `}` stay inside the block at item indentation; a comment written between the tokens of one item moves above that item. Trailing whitespace in comments is removed.
- Text: LF line endings (CRLF input is normalized), no trailing whitespace, exactly one final newline. Strings are written with the canonical escapes `\"`, `\\`, `\n`.
- Properties: idempotent (`fmt(fmt(x)) == fmt(x)`) and AST-preserving (`ast(fmt(x)) == ast(x)` ignoring spans and comments).
- Files with syntax errors are not formatted (returns the diagnostics). If the formatted source would exceed 256 KiB, formatting fails with E109, so formatted output always parses again.

## 8. Charter rendering

Deterministic IR → Markdown. Never uses an LLM. Structure and exact sentences are defined by the golden file `examples/lumen.charter.md` plus these templates. Every default is rendered explicitly.

**Sections in order:** `# <org name>`, purpose paragraph (if any), `## Membership`, `## Changing this charter`, `## Circles` (omitted if none, which needs an org with no goals and `amend: vote(members, …)`), `## Agents` (omitted if none), then per goal `## Goal: <title>` with purpose paragraph, bullet facts, `### Mandates` (omitted if none), `### Rules` (omitted if none), `### Limits`.

**Formatting helpers**
- Money: `$12,000` for whole dollars; otherwise at least 2 and at most 6 decimals, trailing zeros trimmed past 2: `$12.50`, `$0.000125`.
- Durations: `30 minutes`, `1 hour`, `48 hours`, `1 day`, `7 days`, `2 weeks`, `1 year` (singular when 1).
- Dates: `June 30, 2027`.
- Lists: `a`; `a and b`; `a, b, and c`.
- Thresholds: `1/2`→`half`, `1/3`→`one-third`, `2/3`→`two-thirds`, `3/4`→`three-quarters`, other fractions `a/b`, percents `60%`.
- Numbers: counts, vacancies, duration counts and the parts of a fraction threshold are grouped by thousands like metric values: `10,000 seats`, `36,500 days`, `1,000/3,000`.

**Templates**
- Membership: `Anyone signed in to openmaru can join.` / `New members join when N existing member(s) sponsor(s) them.` (N=1: "member sponsors"; N>1: "members sponsor").
- Amend — vote: `Changes need a vote of <C>, passing with at least <T> of its holders in favour within <D>.`; vote members: `Changes need a vote of all members in which at least 20% vote, passing with at least <T> of the votes cast in favour within <D>.`; approve: `Changes need approval from <N> holder(s) of <C> within <D>.` Then `If the vote does not pass in time, the change is rejected.` (vote/deny), `If not approved in time, the change is rejected.` (approve/deny), `If not decided in time, the change is applied.` (allow).
- Circle: `- **<id>**: <S> seat(s), each held for <term>.` or `- **<id>**: <S> seat(s) with no term limit.` then ` Holders: <handles joined by ", ", or none>.` then vacancy ` 1 seat is vacant.` / ` K seats are vacant.` (omitted when 0).
- Agent: `- **<id>** is an AI agent operated by @<op>, running on the hosted runtime.` / `…, running on its operator's own infrastructure.`
- Goal bullets in order: `Stewarded by <C>.`; funding (see below); closure; success (if any).
- Funding: `Receives <$X> from the treasury at the start of each <day|week (Monday)|month>.` / `Receives <$X> from the treasury once, when this goal is first adopted.` / `Is funded only by donations.` Followed (only if `fund` present) by ` If the treasury cannot cover it, work on this goal pauses until it is funded.` or ` If the treasury cannot cover it, work continues with the funds available.`
- Closure: `When closed, its remaining funds return to the treasury.` / `When closed, its remaining funds move to the goal <other title>.`
- Success: `Success means <metric> reaches <at least|more than|at most|less than|exactly> <value with thousands separators>[ by <date>].`
- Mandate: `- **<id or @handle>** may spend up to <$X> per <period> on <AI models|compute|expenses>[ and up to …][, at most <$Y> per request].` Spend clauses are joined with the list helper, in source order (`up to $5 per day on expenses, up to $100 per month on AI models, and up to $20 per week on compute`). If no spend lines: `- **<p>** may not spend funds.` Then ` <It|They> may <capability list>.` (omitted if none; phrases: `claim tasks`, `create tasks`, `post evidence`, `report <metric>`). Then ` This mandate expires on <date>.` if set.
- Rule subject: `Any spend`, `Any spend over $X`, `Any AI-model spend[ over $X]`, `Any compute spend[ over $X]`, `Any expense[ over $X]`, `Closing this goal`.
- Rule: `- <subject> needs <approval from N holder(s) of C | a vote of C, passing with at least T of its holders in favour | a vote of all members in which at least 20% vote, passing with at least T of the votes cast in favour> within <D>; otherwise <outcome>.` Outcome: spend deny `it is denied`, spend allow `it is allowed`, close deny `it stays open`, close allow `it is closed`.
- Limits: `Without any approval, at most <$X> per month can be spent on this goal.`; zero while some mandate has a spend line: `Nothing can be spent on this goal without approval.`; no spend lines at all: `No one may spend from this goal.`

**Text from the spec** (the org name, goal titles, purposes, ids, handles and metric names) is written on one line and renders literally, so it cannot add a heading, list or link to the charter. Each run of whitespace, line breaks included, becomes one space, and the text is trimmed. A backslash goes before `\`, `` ` ``, `*`, `[`, `]` and `~`; before `_` unless it is between two letters or digits; before `<` followed by a letter, `/`, `!` or `?`; and before `&` that starts an entity (`&amp;`, `&#35;`). It also goes before a block marker at the start of the text (`#`; `>`; `-` before a space, `-` or the end; `+` before a space or the end; the `.` or `)` after 1–9 leading digits, as in `1. `), and before the first `#` of a closing run at the end (`Lumen #`). A purpose that is empty after trimming has no paragraph; an empty heading is a bare `#`.

The renderer also returns a structured form for the web UI: `[{"section": "…", "level": 2, "paragraphs": ["…"], "bullets": ["…"]}]`. `section` is the heading text and `level` its Markdown level (1 for the org, 2 for org-level sections and goals, 3 within a goal). Paragraphs come before bullets, and bullets have no `- ` marker. Every string is Markdown inline text (`**bold**` ids, escaped spec text). The escaping is written for a CommonMark renderer of inline content with raw HTML and extensions off (no autolinking of bare URLs); a renderer with GFM's autolinks would turn a URL in a purpose into a link, so SPEC-08 §4 pins the web's renderer (OQ-12). The Markdown charter is built from this form: each heading, paragraph and bullet list is one block, blocks are separated by one blank line, and the file ends with one newline.

## 9. Semantic diff

`diff(ir_before, ir_after) → {changes: [Change], limits: [{goal, before_micros, after_micros}]}`.

Matching keys: circles/agents/goals by `id`; mandates by `(goal, principal)`; rules by `(goal, canonical subject)` (so a changed procedure is `rule_changed`, not remove+add).

`Change = {kind, path, before, after, effect: "loosens"|"tightens"|"neutral", sentence}`.

| kind | effect |
|---|---|
| `purpose_changed`, `goal_purpose_changed`, `goal_title_changed` | neutral |
| `membership_changed` | `open` from `invite` loosens; reverse tightens; sponsor count down loosens / up tightens |
| `amend_changed` | stricter procedure tightens (approve count up, threshold up, `else allow`→`deny`); looser loosens; different circle or kind → neutral |
| `circle_added`, `circle_removed`, `circle_seats_changed`, `circle_term_changed`, `holder_added`, `holder_removed` | neutral |
| `agent_added`, `agent_removed`, `agent_operator_changed`, `agent_runtime_changed` | neutral (runtime `byo`→`hosted` loosens) |
| `goal_added`, `goal_removed`, `goal_steward_changed`, `goal_fund_changed`, `goal_on_underfunded_changed`, `goal_on_close_changed`, `goal_success_changed` | neutral |
| `mandate_added` / `mandate_removed` | loosens / tightens |
| `mandate_limit_changed` (per category; added category = from none) | up or new loosens; down or removed tightens |
| `mandate_period_changed` | compare monthly-normalized limit |
| `mandate_per_request_changed` | up or removed loosens; down or added tightens |
| `mandate_capabilities_changed` | any added loosens; only removed tightens; both → loosens |
| `mandate_expiry_changed` | later or removed loosens; earlier or added tightens |
| `rule_added` / `rule_removed` | tightens / loosens |
| `rule_changed` | stricter procedure or `allow`→`deny` tightens; reverse loosens; otherwise neutral |

Sentences (exact for tested kinds):
- `mandate_limit_changed`: `builder's AI-model limit on Open cloud image editor rises from $4,000 to $6,000 per month.` (`falls` when lower; `is set to $X per month` when newly added; `is removed` when deleted).
- `mandate_added`: `@carol gets a new mandate on Open cloud image editor.`
- `rule_removed`: `Open cloud image editor no longer requires approval for any spend over $500.`
- `holder_added`: `@sam joins core.` / `holder_removed`: `@jo leaves core.`
- Other kinds: `<Thing> changes from <before> to <after>.` using charter formatting helpers.

Changes are ordered: org-level first, then circles, agents, goals in `after` order (removed items last), then within a goal: goal fields, mandates, rules.
