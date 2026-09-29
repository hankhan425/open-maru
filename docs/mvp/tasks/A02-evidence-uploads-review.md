# A02 · Evidence, uploads, review

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | A01 | M | 10 |

**Read first:** SPEC-02 §6.1–§6.3; SPEC-09 §4–§5; SPEC-07 uploads/evidence rows.
**Paths:** `lib/openmaru/{storage,uploads}/**`, `lib/openmaru/tasks/{evidence,review}.ex`, controllers, migrations

## Goal
Work is backed by evidence and verified by stewards. Files (evidence, receipts, proofs) upload directly to private object storage.

## Deliverables
- `Openmaru.Storage` behaviour (`presign_put/3`, `head/1`, `presign_get/2`) with S3 (`ex_aws_s3`) and in-memory fake.
- Migrations `uploads`, `evidence`, `reviews`.
- `Openmaru.Uploads`: `create/2` (purpose, content type, size, sha256 → presigned PUT), `complete/2` (verifies size + checksum via `head`).
- Evidence posting (task and goal level), `submit/2`, `accept/2`, `reject/3`.
- Endpoints; events `evidence.posted`, `task.submitted`, `task.accepted`, `task.rejected`.

## Tests to write first
- [ ] **A02-T01** Presign: allowed types/sizes return a PUT URL with content-type and length constraints; disallowed type or > 10 MB → 422.
- [ ] **A02-T02** Complete: object present with matching size/sha256 → `stored`; mismatch or missing → 422.
- [ ] **A02-T03** Claimant posts evidence kinds `commit`, `pull_request`, `deploy`, `url` (https only; `http://` → 422), `note`, `file` (requires a stored `evidence` upload).
- [ ] **A02-T04** Non-claimant, non-steward → 403; goal-level evidence with `post_evidence` capability → OK.
- [ ] **A02-T05** Submit without evidence → 409 `evidence_required`; with evidence → `in_review`, lease ends `submitted`.
- [ ] **A02-T06** Accept by steward holder → `done`; by the claimant → 403 `self_review_forbidden`; by the claimant agent's operator → 403 `self_review_forbidden`.
- [ ] **A02-T07** Reject requires a non-empty comment → `open`; review row stored.
- [ ] **A02-T08** No update/delete endpoints for evidence; DB trigger rejects UPDATE.
- [ ] **A02-T09** `file` evidence GET returns a 5-minute presigned URL to members only; public listing shows summary without the URL.

## Out of scope
Receipts for expenses (G03 consumes `Uploads`).
