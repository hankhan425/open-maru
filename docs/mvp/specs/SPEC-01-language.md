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
- Circle holders and agent operators are members implicitly.

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
- Rule identity: `"<goal_id>:r_" + first 8 hex chars of SHA-256(canonical rule text)` (canonical text = the formatted `rule …` line without indentation or comments; `maru_core::fmt::rule_line`). Two rules with the same subject in one goal → E314.

### 4.7 Decision procedures
- `approve(C, N)`: passes when N distinct effective holders of circle C approve. Fails early when rejections make N approvals impossible. `members` not allowed (E322). 1 ≤ N ≤ seats(C) (E307).
- `vote(C | members, T)`: eligible voters are snapshotted at decision creation (effective holders of C, or all members). Passes when yes votes ≥ ceil(T × eligible). Fails early when no votes > eligible − required.
- Timeout: at deadline, an undecided procedure resolves to the `else` outcome.

### 4.8 Money, time, periods
- Money is integer micro-USD. `usd 12.50` = 12_500_000. Max per literal 9_007_199_254_740_991 micros (E310). Must be > 0 (E309).
- Periods are UTC calendar periods: day; ISO week starting Monday 00:00; month starting on the 1st 00:00.
- Durations: `m`=60s, `h`=3600s, `d`=86400s, `w`=604800s, `y`=31536000s. At most 100 years = 3_153_600_000 s in any unit (`36500d` and `5214w` pass, `5215w` fails; E104), so every deadline and term end computed from a spec stays within the date range of Elixir, Postgres and JS.
- Counts (`seats`, `sponsors`, approval counts, threshold numbers) are at most 2_147_483_647 (E103), so they fit a Postgres `integer` and a JS number. Metric values have no limit (the IR keeps them as strings, without leading zeros in the integer part).

## 5. Static checks

The checker is pure: `check(source, opts) → {diagnostics, ir?}`. IR is returned only when there are no errors. `opts.now` (optional ISO timestamp) enables time-relative warnings; without it they are skipped so checking stays deterministic.

Checking has two stages. The parser reports E1xx, E2xx, E310 and E311. If it reports any error, `check` returns those diagnostics alone: no semantic checks run and there is no IR. The parser leaves an item with an error out of the tree, so checking that tree would report the same mistake again (a malformed `seats` would also be a missing one, E304). Semantic checks (the other E3xx codes and all W4xx) run only on a source that parses without errors.

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
| W401 | warning | Mandate `expires` is in the past (only with `opts.now`) |
| W402 | warning | `else allow` on a rule or `amend` |
| W403 | warning | A mandate's spend limit for a category exceeds the goal's `fund` normalized to the same period |
| W404 | warning | `on_underfunded` given but the goal has no `fund` |
| W405 | warning | `per_request` exceeds every spend limit of the mandate (no effect) |
| W406 | warning | Agent declared but holds no mandate in any goal |
| W408 | warning | Duplicate capability |

Diagnostic shape (all targets):
```json
{"code":"E302","severity":"error","message":"unknown circle `cor`","span":{"start":{"line":14,"col":14,"offset":301},"end":{"line":14,"col":17,"offset":304}},"notes":["did you mean `core`?"]}
```
Lines and columns are 1-based; columns count Unicode scalar values. "Did you mean" suggestions use Levenshtein distance ≤ 2.

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
    "amend": {"procedure": {"kind": "vote", "circle": "core", "threshold": {"num": 2, "den": 3}},
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
Thresholds are stored as fractions: `60%` → `{"num":60,"den":100}` (not reduced); `2/4` stays `{"num":2,"den":4}`. Durations keep their source unit (`{"value":48,"unit":"h","secs":172800}`) so the charter can say "48 hours". `term` is `null` when absent. Defaults are materialized in the IR (never absent); the default timeout is `{"value":7,"unit":"d","secs":604800}`.

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

**Sections in order:** `# <org name>`, purpose paragraph (if any), `## Membership`, `## Changing this charter`, `## Circles`, `## Agents` (omitted if none), then per goal `## Goal: <title>` with purpose paragraph, bullet facts, `### Mandates` (omitted if none), `### Rules` (omitted if none), `### Limits`.

**Formatting helpers**
- Money: `$12,000` for whole dollars; otherwise at least 2 and at most 6 decimals, trailing zeros trimmed past 2: `$12.50`, `$0.000125`.
- Durations: `30 minutes`, `1 hour`, `48 hours`, `1 day`, `7 days`, `2 weeks`, `1 year` (singular when 1).
- Dates: `June 30, 2027`.
- Lists: `a`; `a and b`; `a, b, and c`.
- Thresholds: `1/2`→`half`, `1/3`→`one-third`, `2/3`→`two-thirds`, `3/4`→`three-quarters`, other fractions `a/b`, percents `60%`.

**Templates**
- Membership: `Anyone signed in to openmaru can join.` / `New members join when N existing member(s) sponsor(s) them.` (N=1: "member sponsors"; N>1: "members sponsor").
- Amend — vote: `Changes need a vote of <C>, passing with at least <T> of its holders in favour within <D>.`; vote members: `Changes need a vote of all members, passing with at least <T> of them in favour within <D>.`; approve: `Changes need approval from <N> holder(s) of <C> within <D>.` Then `If the vote does not pass in time, the change is rejected.` (vote/deny), `If not approved in time, the change is rejected.` (approve/deny), `If not decided in time, the change is applied.` (allow).
- Circle: `- **<id>**: <S> seat(s), each held for <term>.` or `- **<id>**: <S> seat(s) with no term limit.` then ` Holders: <handles or none>.` then vacancy ` 1 seat is vacant.` / ` K seats are vacant.` (omitted when 0).
- Agent: `- **<id>** is an AI agent operated by @<op>, running on the hosted runtime.` / `…, running on its operator's own infrastructure.`
- Goal bullets in order: `Stewarded by <C>.`; funding (see below); closure; success (if any).
- Funding: `Receives <$X> from the treasury at the start of each <day|week (Monday)|month>.` / `Receives <$X> from the treasury once, when this goal is first adopted.` / `Is funded only by donations.` Followed (only if `fund` present) by ` If the treasury cannot cover it, work on this goal pauses until it is funded.` or ` If the treasury cannot cover it, work continues with the funds available.`
- Closure: `When closed, its remaining funds return to the treasury.` / `When closed, its remaining funds move to the goal <other title>.`
- Success: `Success means <metric> reaches <at least|more than|at most|less than|exactly> <value with thousands separators>[ by <date>].`
- Mandate: `- **<id or @handle>** may spend up to <$X> per <period> on <AI models|compute|expenses>[ and up to …][, at most <$Y> per request].` If no spend lines: `- **<p>** may not spend funds.` Then ` <It|They> may <capability list>.` (omitted if none; phrases: `claim tasks`, `create tasks`, `post evidence`, `report <metric>`). Then ` This mandate expires on <date>.` if set.
- Rule subject: `Any spend`, `Any spend over $X`, `Any AI-model spend[ over $X]`, `Any compute spend[ over $X]`, `Any expense[ over $X]`, `Closing this goal`.
- Rule: `- <subject> needs <approval from N holder(s) of C | a vote of C, passing with at least T of its holders in favour | a vote of all members, passing with at least T of them in favour> within <D>; otherwise <outcome>.` Outcome: spend deny `it is denied`, spend allow `it is allowed`, close deny `it stays open`, close allow `it is closed`.
- Limits: `Without any approval, at most <$X> per month can be spent on this goal.`; zero with mandates present: `Nothing can be spent on this goal without approval.`; no spend lines at all: `No one may spend from this goal.`

The renderer also returns a structured form: `[{"section": "…", "paragraphs": ["…"], "bullets": ["…"]}]` for the web UI.

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
