# P01 · Stripe Connect onboarding & webhooks

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | C02, C03 | M | 8 |

**Read first:** SPEC-05 §1–§3, §4.2 (webhook plumbing), §7; SPEC-09 §3, §6.
**Paths:** `lib/openmaru/payments/**`, `lib/openmaru_web/controllers/stripe_webhook_controller.ex`, migrations

## Goal
Org administrators connect their own Stripe account; webhooks are received securely and processed exactly once.

## Deliverables
- `Openmaru.Payments.StripeClient` behaviour (full callback list from SPEC-05 §7) + `stripity_stripe` implementation + Mox mock.
- Migrations `stripe_accounts`, `stripe_events`.
- Administrators per SPEC-05 §2 through C03's `Orgs.administrators/1`.
- `stripe_accounts.connected_by_user_id`: the administrator who started onboarding (P05 uses it for payments continuity, SPEC-05 §8.8).
- Onboarding + status endpoints.
- Two webhook endpoints with separate secrets, raw-body signature verification, store-then-process via Oban worker, dispatch by event type (only `account.updated` handled here; P02 adds more handlers through a dispatch map).

## Tests to write first
- [ ] **P01-T01** Administrator requests onboarding → account created once (mock), account link URL returned; second call reuses the account.
- [ ] **P01-T02** Non-administrator member → 403.
- [ ] **P01-T03** `amend: vote(members, …)` → every effective holder of any circle is an administrator.
- [ ] **P01-T04** Signed `account.updated` → status fields updated; bad signature → 400; timestamp outside 5-minute tolerance → 400.
- [ ] **P01-T05** Duplicate event id → 200, processed once.
- [ ] **P01-T06** Handler error → Oban retries; `stripe_events.error` recorded; success clears it and sets `processed_at`.
- [ ] **P01-T07** `GET /payments/status` returns flags and a human summary of `requirements.currently_due`.
- [ ] **P01-T08** Event for an unknown connected account → stored, marked processed, warning logged.

## Out of scope
Donations (P02), reconciliation (P03).
