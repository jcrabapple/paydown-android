# ANDROID1: Paydown Android app — implementation spec

> **Design record.** This is the spec the first version was built from. The
> decisions (A1–A9) and the per-screen endpoint contracts still hold; the
> "lane" sections describe how the work was split during that build. Where
> prose and `docs/openapi.json` disagree, the schema wins (the test suite
> enforces it).

Flutter client for a self-hosted Paydown server. Full feature parity
with the web app's daily-driver flows. Backend contract: the budget repo's
existing `/api/*` endpoints plus `docs/API1.md` (`/api/mobile/home`,
android-aware link tokens). Real, scrubbed response shapes live in
`docs/fixtures/*.json` — code against those field names exactly.

## Decisions

- A1: Framework Flutter 3.47, Dart records/patterns allowed, Material 3.
  Package `us.snakepit.paydown` (register your build's id with Plaid; see
  the server repo's `docs/API1.md`, D5).
- A2: Auth = HTTP Basic, credentials in `flutter_secure_storage` (foundation
  `AuthStore`). Never log credentials. Never set an `Origin` header
  (foundation `HttpApiClient` already complies).
- A3: No state-management package. Each screen is a `StatefulWidget` that
  fetches in `initState`, exposes pull-to-refresh via foundation `Refresher`,
  and re-fetches after its own mutations. `IndexedStack` keeps tab state.
- A4: Errors: surface `ApiError.message` persistently (foundation
  `AsyncView` Retry pattern or a banner); success: `toast()` and re-fetch.
  Never auto-vanish an error, never style a success as an error.
- A5: Money is integer cents everywhere; render only through
  `format.dart money()`. Never divide in a widget.
- A6: Widget tests only, against `FakeApiClient` (foundation). Every screen
  test wraps the screen in `ApiScope(client: FakeApiClient({...}))` plus a
  `MaterialApp`/`Scaffold`. No network in tests. Gate: `flutter analyze`
  clean (no issues) and `flutter test` green.
- A7: Reuse the web app's semantic invariants (budget repo skill): the
  recurring extra is `recurring_debt_budget_cents - minimums_total_cents`,
  never this month's total extra; split minimum vs planned extra on any
  "owed" display; min $0 on a synced card means THIS cycle is satisfied.
- A8: Plaid Link: `plaid_flutter` 5.2.1. Token via
  `POST /api/plaid/link-token {"android_package_name": "us.snakepit.paydown"}`,
  then `PlaidLink.create(LinkTokenConfiguration(token: ...))`,
  `PlaidLink.open()`, success stream → `POST /api/plaid/exchange`
  `{public_token, institution_name}`. Wrap streams with cancelable
  subscriptions; never leave them listening after dispose.
- A9: Automated work must NEVER complete a real Plaid Link flow against a
  production server (Plaid Trial items are a lifetime quota); tokens in tests
  are fake strings. Real bank connections are done by a person, by hand.

## Foundation (landed, do not modify)

- `lib/api/client.dart` — `ApiClient` (abstract), `HttpApiClient`, `ApiError`.
- `lib/api/auth.dart` — `AuthStore`, `Credentials`.
- `lib/api/fake.dart` — `FakeApiClient` (routes map `"METHOD /path"` or
  `"/path"` for GET → payload | thrown `ApiError` | fn(body); `calls` log).
- `lib/widgets.dart` — `ApiScope.of(context)`, `AsyncView`, `toast`,
  `Refresher`, `InfoRow`.
- `lib/format.dart` — `money`, `pct`, `monthLabel`, `shortDate`.
- `lib/main.dart` — session root + `HomeShell` bottom nav (Today, Plan,
  Accounts, More) + sign-out. **Lane files are wired in; do not touch.**
- `lib/screens/login.dart`, `lib/screens/more.dart` — orchestrator-owned.

## Lane ownership

Lanes own exactly their listed files (create/replace the placeholder) and
their own `test/<lane>_test.dart`. NOTHING else. Shared-file changes are
reported in the lane summary, not made. Two lanes never share a file.

| Lane | Files | Fixtures |
|---|---|---|
| A — Today | `lib/screens/today.dart`, `test/today_test.dart` | mobile_home, safe_to_spend, upcoming, reminders |
| B — Plan | `lib/screens/plan.dart`, `test/plan_test.dart` | mobile_home, expenses |
| C — Bills & Payments | `lib/screens/bills.dart`, `lib/screens/payments.dart`, `test/bills_payments_test.dart` | expenses, payments, mobile_home |
| D — Accounts & Plaid | `lib/screens/accounts.dart`, `test/accounts_test.dart` | cards, cash_accounts, plaid_status, plaid_accounts, mobile_home |
| E — Subscriptions & Goals | `lib/screens/subscriptions.dart`, `lib/screens/goals.dart`, `test/subscriptions_goals_test.dart` | subscriptions, goals, expenses |
| F — Insights & Settings | `lib/screens/insights.dart`, `lib/screens/settings.dart`, `test/insights_settings_test.dart` | insights_debt_trend, insights_spending, settings, income, pay_schedules, deposit_rules |

## Screen specs

### Lane A — Today (`today.dart`)
`GET /api/mobile/home` is the only fetch (D6). Sections, in order:
1. **Safe-to-spend hero**: `safe_to_spend_cents` big; subtitle `per_day_cents`
   and `days_until` horizon; tap → dialog with the waterfall
   (`cash_total_cents`, `pending_out_cents`, `obligations_total_cents` +
   `obligations` list, `planned_extra_cents` informational — A7) and any
   `warnings` strings.
2. **Reminders** (`reminders`): rows with `shortDate(date)`, name, amount;
   honor `overdue`/`note` flags with warn styling (see fixture).
3. **Upcoming** (`upcoming`, 30d): grouped by date; `status`
   (`expected`/`due`/`on_card`/`paid`/`target`) as colored chip; for
   `kind: "card"` rows render `min_remaining_cents` vs
   `extra_remaining_cents` separately (A7).
4. **Unlogged card payments** (when `unlogged_card_payment_count > 0`):
   banner button pushing a log flow — `GET /api/card-payments/unlogged`,
   each row → `POST /api/card-payments/{transaction_id}/log` or `/dismiss`,
   plus a "Log all" → `POST /api/card-payments/log-all`. Refetch after.
RefreshIndicator refetches the home payload.

### Lane B — Plan (`plan.dart`)
`GET /api/mobile/home`. Sections:
1. **Month header**: `monthLabel(month)`; budget summary tiles:
   `paid_total_cents` / `recommended_total_cents`; `budget.debt_budget_cents`,
   `budget.recurring_debt_budget_cents`, `budget.minimums_total_cents`, and
   the recurring extra computed as
   `recurring_debt_budget_cents - minimums_total_cents` (A7 — never show
   one-off-inflated totals as recurring).
2. **Plan rows** (`plan`): per card — name, `paid_cents` of
   `recommended_cents` (linear progress), `remaining_cents` split into
   `min_remaining_cents` + extra chip; `bank_overdue` badge when true.
3. **Strategy projection**: strategy picker (avalanche/snowball/custom from
   `settings.strategy`); per `projection[strategy]`: payoff
   `months`, `interest_total_cents`, `interest_saved_cents` vs
   `minimums_only` (`null` + `minimums_only_never` → render "minimums never
   pay this off", never $0 saved — A7); schedule as a compact
   month-by-month list (first 12 rows + "…").
4. **Use spare cash** (current month only): button → fetch
   `GET /api/safe-to-spend`, dialog with spare amount + custom-cents field,
   `POST /api/month/{month}/use-cash {amount_cents}` (omit body for full
   sweep); 409 for past months never surfaces (button hidden off-current
   month). Toast + refetch after.
5. **Adjustments**: `POST /api/adjustments {month, name, amount_cents, kind}`
  with `kind: "bonus"`, list this month's, delete via
   `DELETE /api/adjustments/{id}`. (Shape: see web app; amounts are cents.)

### Lane C — Bills & Payments
Bills (`bills.dart`): `GET /api/expenses`. Tabs by `kind` (`bill`/`spending`).
CRUD dialogs (name, amount dollars→cents, due_day for bills, `paid_from`
cash/card, active). `POST /api/bills/{id}/paid {due_date}` marks the current
occurrence paid; `DELETE /api/bills/{id}/paid/{due_date}` unmarks. Show next
due date + paid state from `upcoming` logic client-side (due_day within
current month) — simplest: use `GET /api/upcoming?days=31` and match rows.
Payments (`payments.dart`): `GET /api/payments?month=` (month picker);
`POST /api/payments {card_id, amount_cents, paid_on, month?, note?}`
(`paid_on` is REQUIRED by `PaymentIn`); `DELETE /api/payments/{id}`. List grouped by card.

### Lane D — Accounts & Plaid (`accounts.dart`)
Sections:
1. **Cash accounts** (`GET /api/cash-accounts`): name, balance (`money`),
   `include_in_cash` switch → `PUT /api/cash-accounts/{id}`; add/edit
   (name, balance dollars→cents) → POST/PUT; delete → `DELETE`.
2. **Cards** (`GET /api/cards`): name, `balance_cents`, effective `apr`
   (render `bank_apr` grayed when override differs), `min_payment_cents`,
   `next_due_date`, `bank_overdue`, utilization bar
   (`utilization_pct`). Edit dialog: APR override + min override with a
   "clear override" action (`PUT /api/cards/{id}` with explicit nulls for
   `apr_override`/`min_override_cents`); never edit APR/min directly on
   synced cards (form disables, A7). Add card (manual) POST; close/delete
   per web semantics (`DELETE /api/cards/{id}`).
3. **Plaid** (`GET /api/plaid/status`, `/api/plaid/accounts`): item rows
   (institution, status, error_code, last_synced_at, account count);
   "Sync now" → `POST /api/plaid/sync`; "Connect bank" → A8 flow;
   per-account link → `POST /api/plaid/accounts/{id}/link {card_id?}` /
   `{cash_account_id?}`, unlink, ignore; item delete →
   `DELETE /api/plaid/items/{id}` with confirm dialog. Render `error_code`
   verbatim when present. Plaid not configured (`configured: false`) →
   hidden section.
   Link success handling: on `PlaidLink.onSuccess` extract
   `success.publicToken` + metadata institution name →
   `POST /api/plaid/exchange`. onExit → dismiss silently (log nothing
   sensitive).

### Lane E — Subscriptions & Goals
Subscriptions (`subscriptions.dart`): `GET /api/subscriptions` — active
(sorted, `next_renewal`, `monthly_cents` equivalent) + totals tile
(`monthly_cents`/`annual_cents`); cancelled under an expansion tile.
CRUD: POST/PUT `/api/subscriptions {name, amount_cents, cycle, next_date, match_text?, note?}`;
cancel/reactivate/delete endpoints per web (`POST .../cancel`,
`POST .../reactivate`, `DELETE`). Suggestions (`GET
/api/subscriptions/suggestions`, `POST .../suggestions/dismiss {key}`,
`POST /api/subscriptions/from-expense/{expense_id}`) as a "Detected" section.
Goals (`goals.dart`): `GET /api/goals` rows with name, target, set-aside,
target_date; CRUD + `POST /api/goals/{id}/move {from_goal_id, amount_cents}`
as a transfer dialog. See fixtures + web app field names.

### Lane F — Insights & Settings
Insights (`insights.dart`): `GET /api/insights/debt-trend` — per-month
charges/payments/refunds/interest/fees + net, excluding partial months
except the last (`partial` flag) — headline = newest non-partial; chart-free:
colored table/list is fine (no chart package — YAGNI).
`GET /api/insights/spending` — per-category monthly averages; suggestions
checklist (if present in payload) POSTs to `/api/expenses` kind `spending`.
Settings (`settings.dart`): strategy picker + numeric fields →
`PUT /api/settings` (fields per fixture); income CRUD (`/api/income`);
pay schedules (`GET/POST/PUT/DELETE /api/pay-schedules`, `POST
/api/pay-schedules/detect`, `POST /api/pay-schedules/{id}/use-as-income`);
deposit rules list + preview link-out (`/api/deposit-rules`,
`/api/deposit-rules/preview`).

## Definition of done (every lane)

1. `flutter analyze` — zero issues.
2. `flutter test` — lane tests green: render-from-fixture, at least one
   user action (tap → correct ApiClient call recorded in `fake.calls`), and
   one error path (route throws `ApiError` → message visible).
3. No edits outside owned files (verify with `git status` before reporting).
4. Report: files changed, test count, any contract surprises (field missing
   from fixture, endpoint behaving oddly) — do NOT silently invent fields.

## Build notes

- Flutter SDK: `~/development/flutter/bin/flutter`.
- No system JDK: use Android Studio flatpak JBR —
  `export JAVA_HOME=/var/lib/flatpak/app/com.google.AndroidStudio/current/active/files/extra/jbr`
  (needed only for `flutter build`, not analyze/test).
- Debug APK build verified 2026-10-27 with plaid_flutter 5.2.1 integrated.

## Contract schema

`docs/openapi.json` is the server's OpenAPI schema, exported from the budget
repo. Every `FakeApiClient` request in the test suite is validated against it
(`test/contract.dart`, installed by `test/flutter_test_config.dart`): unknown
routes, missing required fields, unknown fields, and wrong JSON types fail the
test. Regenerate it whenever server models change:

```bash
cd ../budget && T=$(mktemp -d) && uv run python -c "
import json; from app.main import create_app
spec = create_app('$T/x.db', 'u', 'p').openapi()
json.dump(spec, open('../paydown-android/docs/openapi.json', 'w'), indent=1, sort_keys=True)"
```
