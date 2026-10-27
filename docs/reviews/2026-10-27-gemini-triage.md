# Android review triage — Gemini 3.8 Flash high, 2026-10-27

Reviewed snapshot: `1a1b44d` (BEFORE the bugfix commit `683833e`).
32 findings. Every one checked against current code and the server source.

## Already fixed in 683833e (review saw the old code)
5 (login setState after await), 8 (non-JSON 200 / Socket/TLS unmapped),
9 (no timeout), 11–16 (double*100 money parsing), 22 (URL normalization),
23 (credentials saved before validation), 26 (errors auto-vanish).

## Accepted, fixed in this round
| # | Finding | Fix |
|---|---|---|
| 2, 25, 27, 28 | Unlogged-payments page: setState after dispose; Log all removed nothing (server returns `{logged, linked}`, page guessed `tx='log-all'`); buttons in a detached second list; Dismiss toasted "Card payments logged"; no double-tap guard | Page rewritten: busy guard, mounted checks, per-row Card with its own buttons, per-action messages, server refetch after every mutation |
| 3, 4 | goals/subscriptions `_fail` setState after dispose | `mounted` guard |
| 6 | `as int` cast on goal suggestion cents | `(as num).toInt()` (server sends ints today; defensive) |
| 17 | Debt-trend colors inverted (paying down shown red) | positive net = error, negative = green (theme-aware), zero neutral |
| 20 | Card edit inverted vs web: synced cards had override fields DISABLED; manual edits wrote overrides | Mirrors web form: synced → APR/min overrides (blank = bank) with bank hints; manual → balance/APR/min; inline validation. Old test pinning the disabled fields replaced |
| 24 | 401 strands the user in Retry loops | `HttpApiClient.onUnauthorized` → session root clears creds once and returns to login |
| 29 | Spending tab FAB always added a bill | FAB reads the active tab |
| 31 | `_NumTile` controller stale after reload / cancelled edit | re-seeded from current value on every open |
| 32 | Partial-month filter was an identity op | drop partial months except the trailing current one |

## Accepted-narrowed → SERVER fix (budget repo)
30: Android Settings reads `/api/settings` (bool, correct), so the screen is
fine. But `/api/mobile/home` returns `settings.auto_log_card_payments` as the
raw int `1`, unlike `/api/settings` — API1 promised identical semantics. Fix
the aggregate on the server.

## Rejected
| # | Reason |
|---|---|
| 1 | `_subscription_view` is `dict(row)` + extras, so `next_date` IS present; active rows always get a non-null `next_renewal`, and `_activeRow` only renders active rows |
| 7 | `month` is always set by the server's month bundle; no plausible input omits it |
| 10 | `GET /api/card-payments/unlogged` returns `list[dict]` (txns.unlogged_card_payments signature); the `items` branch was in `_act`, now removed |
| 18 | OpenAPI `SubscriptionIn` fields are `cycle` + `next_date`; ANDROID1.md's `frequency`/`next_renewal` wording was wrong, the code was right (contract check enforces it) |
| 19 | `SubscriptionDismissIn` requires `key`, not `transaction_id` (same: spec prose wrong, code right) |
| 21 | `CashAccountIn` has no required fields; blank balance is accepted |
