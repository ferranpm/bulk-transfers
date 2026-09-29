# PLAN — Qonto bulk transfer service

`challenge/` is gitignored: this plan is local working material. Everything an agent needs at commit time (conventions, decisions, fixtures) is copied into committed files by the steps below.

---

## 0. How agents execute this plan

- **Sequential, one step per session.** Take the first unchecked step in [§6](#6-implementation-steps), do only that step, then stop.
- Before starting: read `CLAUDE.md` (repo root, created in step 6), this plan, and the decision records referenced by the step.
- The DB and web containers are already running. **Every command runs inside the web container:**
  - Validity gate (the only command you need): `docker compose exec web bin/ci`
  - Ad-hoc: `docker compose exec web bin/rspec spec/path_spec.rb`, `docker compose exec web bin/rubocop -a`
  - After changing the Gemfile: `docker compose exec web bundle install`
- Red/green TDD for every behaviour step: write the failing spec, run it and see it fail for the right reason, implement, get to green, then run `bin/ci` and see it green.
- Commit rules:
  - Work happens **on `main`** (user decision, see ADR `git-workflow`).
  - Use `git add <file>` explicitly. Never use `git add .` or `-A`. Check `git diff --cached --stat` before committing, and verify that no secrets (`config/master.key`, `.env*`) are staged.
  - Write imperative subjects under 72 characters. Use the commit subject(s) given in the step.
  - Keep kinds of change separate: lint autocorrect, config, docs and behaviour never share a commit. If a step lists several commits, make them in order.
  - End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tick the step's checkbox in this file when it's committed (this file is not committed).
- If a step reveals that a decision is wrong, **stop and ask the user**. If the user agrees to change it, amend the decision record in its own `docs:` commit and update this plan.

---

## 1. Decisions

Each decision gets a record in `docs/decisions/<timestamp>-<slug>.md`, written in step 7. Every record has **Context** (explain the problem in enough depth that a reviewer who hasn't read the brief understands why it matters), **Chosen**, **Discarded (why)** and **Consequences**. Timestamps are `20260928` + a 4-digit sequence in the order below (e.g. `202609280001-api-success-status-and-body.md`).

| # | Slug | Chosen | Discarded (why) |
|---|------|--------|-----------------|
| 1 | `api-success-status-and-body` | **201 Created** with a JSON body describing the bulk and every created transfer. We document the conflict. | 204 no body (the client can't map its items to the created transaction ids); 201 with id only (same problem); body that includes the resulting balance (it goes stale, and a replay would return an inconsistent number). |
| 2 | `idempotent-replay-response` | Same key + same fingerprint → **200 OK** with the *same body* as the original 201, rebuilt from the DB. The 200 tells the client nothing new was created. | Identical 201 (Stripe-style; it hides whether the request was replayed, which makes support and debugging harder). |
| 3 | `keep-full-rails-stack` | Keep the generated full Rails app (propshaft, action_view). The bulk controller inherits from a dedicated `Api::BaseController < ActionController::API`, so there's no CSRF, session or cookie handling. | Convert to `api_only` (churn for no functional gain in this exercise); regenerate with `--api` (throws away the provided Docker setup); inherit from `ApplicationController` + `skip_forgery_protection` (easy to forget, and it drags in browser concerns). |
| 4 | `postgresql-and-seeds` | PostgreSQL 17. `db/seeds.rb` **hardcodes** the single account and two transactions from `qonto_accounts.sqlite` (with their ids). It inserts with `insert_all` and on-conflict-do-nothing, so re-seeding never resets a balance, and then resets the PK sequences. | Read the sqlite file at seed time (extra `sqlite3` gem, and it depends on a gitignored file); upsert (re-running seeds would overwrite a live balance); keep SQLite (no real row locks, and single-writer semantics hide the concurrency problem we need to solve). |
| 5 | `money-representation` | `bigint` cents in the DB (`*_cents`) and Integer cents in Ruby. The EUR-only rule is enforced by a `CHECK` and a constant. Amount strings are parsed with **lenient BigDecimal** behind a character whitelist `\A[0-9.]+\z`. We then reject nil (unparseable), values `<= 0`, values with more than 2 decimals, and values above `MAX_AMOUNT_CENTS` (10^15). JSON numbers are rejected by checking the raw type. | Floats (rounding loses cents); money-rails (a gem for a single-currency problem); a strict regex grammar (the user chose leniency, so "1.500" and ".5" are accepted); bare BigDecimal without the whitelist (it would accept "1e3", whitespace and "Infinity"). |
| 6 | `denormalized-balance-with-movement-log` | `bank_accounts.balance_cents` stays the source of the funds check. `transactions` is an append-only movements log written in the same DB transaction, with debits negative. Invariant: `balance_cents == SUM(transactions.amount_cents)`. The seeded data already satisfies this (11,000,000 − 1,000,000 = 10,000,000). | Balance computed from `SUM` on every request (O(n) per check, and you still need a lock); event sourcing (out of scope). |
| 7 | `schema-changes` | Keep the provided table and column names. Use Rails defaults: bigint ids and `created_at`/`updated_at` on every table. New `bulk_transfers` table. `transactions.bulk_transfer_id` is a nullable FK (the seeded rows have none). DB constraints: `balance_cents >= 0`, `amount_cents <> 0`, `amount_currency = 'EUR'`, `char_length(counterparty_name) <= 70`, `char_length(description) <= 140`, `NOT NULL` where the contract requires it, FKs, `UNIQUE (iban, bic)` on accounts, `UNIQUE (bank_account_id, idempotency_key)` on bulks, and an index on `transactions (bank_account_id)` and `(bulk_transfer_id)`. | Integer ids / no timestamps (strict copy of the sample schema, but no audit trail); a separate `idempotency_keys` table storing response snapshots (more generic, but the bulk row already holds everything needed to rebuild the response). |
| 8 | `pessimistic-row-lock` | A single `SELECT … FOR UPDATE` on the bank account row at READ COMMITTED. Under that lock we check the idempotency key, check funds, insert the bulk and its transactions, update the balance, then commit. It's the **only** lock the operation takes, and any future second lock must follow a fixed order. `transaction(requires_new: true)`. | Conditional `UPDATE … WHERE balance_cents >= total` (it prevents double spends, but the idempotency check isn't serialized: two same-key retries both debit and rely on `RecordNotUnique` plus a re-read, and the funds rule ends up in SQL); optimistic `lock_version` (retry storms on a hot payroll account); SERIALIZABLE (a retry loop around every transaction, and predicate-lock overhead); advisory locks (a second locking scheme that future code must remember); Ruby `Mutex` / Redis lock (not shared across instances, or extra infrastructure). |
| 9 | `idempotency-key-and-fingerprint` | A required `Idempotency-Key` header of 1–255 characters, opaque (the README recommends a UUID). A missing or blank key → 400 `missing_idempotency_key`; longer than 255 → 400 `invalid_idempotency_key`. The key is scoped per account. The fingerprint is SHA-256 of **canonical JSON of the whitelisted params**: keys sorted, `credit_transfers` order preserved, amounts as sent. Unknown fields are ignored. Only successful bulks are persisted, so a failed request retried with the same key is evaluated again. The key lookup happens under the account lock, with `RecordNotUnique` rescued as a backstop that re-reads the row. | Optional key (no retry safety); UUID-only key (needlessly strict); fingerprint of the raw body bytes (whitespace or key-order changes on a legitimate retry would cause a false `idempotency_key_reused`); persisting failures (a client could never retry after topping up the account). |
| 10 | `request-validation` | Collect **all** errors into `details` as `[{ index:, field:, issue: }]` (index is omitted for top-level fields). Rules: required fields present and strings; `credit_transfers` a non-empty array of objects; currency `EUR`; BIC `\A[A-Z0-9]{8}([A-Z0-9]{3})?\z`; IBAN `\A[A-Z]{2}\d{2}[A-Z0-9]{1,30}\z`; name ≤ 70; description ≤ 140; amount per decision 5. **No cap on bulk size.** All provided sample IBANs and BICs pass these regexes (verified). | Fail-fast (poor developer experience for bulk clients); presence-only IBAN/BIC; full mod-97 checksum via the `ibandit` gem (the right production answer, which the **README must recommend**, but it risks rejecting the synthetic sample data); capping at 1,000 transfers (the user chose no cap, and the README documents the lock-duration and timeout risk). |
| 11 | `non-json-requests` | Malformed JSON **and** a missing or wrong `Content-Type` → 400 `invalid_json`. A body that isn't a JSON object → 422 `validation_failed`. | 415 for Content-Type (one more status to explain for little benefit). |
| 12 | `bulk-insert-strategy` | A single `insert_all` for all transaction rows, with `RETURNING id`. Validation already ran in the request parser, and the DB CHECKs are the backstop. It carries an inline `# rubocop:disable Rails/SkipsModelValidations` with a *why* comment. Response items are ordered by `id`: Postgres assigns `nextval` in `VALUES` order for a single multi-row insert. The ADR states this assumption. | `create!` per row (N round trips while holding the account lock, which matters because there's no bulk cap). |
| 13 | `timeouts-and-unavailability` | `database.yml` `variables`: `lock_timeout` defaults to `2s` and `statement_timeout` to `10s`, both overridable by ENV (`DB_LOCK_TIMEOUT`, `DB_STATEMENT_TIMEOUT`) so specs can use short values. `LockWaitTimeout`, `Deadlocked`, `QueryCanceled`, `ConnectionNotEstablished`/`ConnectionFailed` and `ConnectionTimeoutError` → 503 `service_unavailable` with `Retry-After: 1`. | 5s/30s (slower failure under contention, and the client has to retry anyway); no Retry-After. |
| 14 | `error-model` | `DomainError` base in `app/errors/`, where each subclass is `configure code:, http_status:, default_message:`. A single envelope `{ "error": { "code", "message", "details" } }`. | Rails' default error pages / ad-hoc hashes per controller. |
| 15 | `operations-and-result` | Thin controller → one operation `BulkTransfers::Create.call(...)` → always a frozen `Result`. Inner services (`Ledger`) raise. `TransactionGuard.ensure_transaction!`. All money mutations go through `Ledger`. Models hold no callbacks. The `Result` class is hand-rolled. | dry-monads / Interactor / Trailblazer (a gem for about 20 lines); fat models with callbacks (hidden money movement). |
| 16 | `structured-logging` | A `StructuredLog` module that emits single-line `event=… key=value`. Events: `bulk_transfer.accepted` (account id, count, total cents, `duration_ms`), `.rejected` (reason code), `.replayed`, `.unavailable`. No IBANs, bodies or keys. | lograge / semantic_logger (a gem for about 20 lines). |
| 17 | `dev-environment` | Docker Compose with `postgres:17-alpine`. `database.yml` reads `DATABASE_HOST/PORT/USER/PASSWORD` with fixed DB names (`qonto_development`, `qonto_test`), and `DATABASE_NAME` is removed from compose. **No entrypoint**: reviewers run `docker compose run --rm web bin/setup` (bundle install, `db:prepare`, seeds) and then `docker compose up`. Agents run everything via `docker compose exec web …`. Multiple instances are proven by the concurrency specs, not by compose. | An entrypoint that runs bundle and `db:prepare` on up (the user declined it); baking gems into the image (rebuild on every Gemfile change); keeping Postgres 14.2; an nginx + 2 replicas demo (moved to Not built yet); running specs on the host (the container is the single source of truth). |
| 18 | `quality-gate` | `bin/ci` (Rails 8.1 `ActiveSupport::ContinuousIntegration`) is **the** gate. It runs Setup, Style (RuboCop with rails, rspec, performance and factory_bot plugins, `NewCops: enable`), Security (Brakeman, bundler-audit), Test DB prepare, and Tests (RSpec). | Separate commands per agent (easy to skip one); no security scans. |
| 19 | `testing-strategy` | RSpec + FactoryBot, diamond-shaped. Request specs are the largest layer (every status and code, `sample1.json` → 201, `sample2.json` → 422). Unit specs cover branchy rules. Operation specs assert result, balance and rows together. `:concurrency` specs use real threads with transactional tests off and `database_cleaner-active_record` truncation. A shared `expect_ledger_invariants!` helper. Every failure-path spec asserts that nothing changed. Arrange/Act/Assert separated by blank lines, without section comments. Never mock the DB or locks. | Hand-rolled TRUNCATE (the user preferred the common gem); mocking locks (proves nothing). |
| 20 | `git-workflow` | Commit the untouched scaffold on `main`, then keep working on `main` (the user overrides the global "no commits to main" rule for this repo). | A feature branch + PR. |
| 21 | `agent-conventions` | A committed `CLAUDE.md` at the repo root that distills the engineering checklist's layering, naming, style and testing rules plus the agent protocol from §0, so conventions are loaded automatically and visible to reviewers. | Pointing agents at the gitignored checklist (not versioned, and invisible to reviewers). |
| 22 | `debrief-in-readme` | The debrief answers live in README sections (Operational scenarios, Scaling, Not built yet). The README goes **outside-in**: challenge → product solution → technical details. | A separate `docs/DEBRIEF.md`; local-only notes; a technical-first README (the reader meets the mechanics before the problem they solve). |

### Deviations from the checklist

| The checklist says | This plan does | Decision |
|---|---|---|
| 204 on success / replay | 201 + body on success, 200 + same body on replay | 1, 2 |
| Rails API-only app | Full stack kept; `ActionController::API` base for the API | 3 |
| Seeds load from `qonto_accounts.sqlite` | Seeds hardcode the same data | 4 |
| Strict positive amount with ≤ 2 decimals | Lenient BigDecimal behind a `[0-9.]` whitelist | 5 |
| Entrypoint runs `db:prepare` + seeds; `docker compose up` alone works | `docker compose run --rm web bin/setup`, then `docker compose up` | 17 |
| (implicit) feature branch | Everything on `main` | 20 |
| README is technical first | README goes outside-in: challenge → product solution → technical details | 22 |
| Non-EUR currency as its own 422 | Reported inside `validation_failed` details (`issue: "unsupported_currency"`) | 10 |

---

## 2. Invariants (tests must prove every one)

1. **Non-negative balance:** `bank_accounts.balance_cents >= 0` at all times (code check + DB `CHECK`).
2. **Reconciliation:** for every account, `balance_cents == SUM(transactions.amount_cents)`.
3. **Atomicity:** a bulk is either fully applied (1 `bulk_transfers` row + N `transactions` rows + balance decreased by the total) or not at all.
4. **Bulk consistency:** for each bulk, `COUNT(transactions) == transfer_count` and `SUM(amount_cents) == -total_amount_cents`.
5. **Idempotency:** at most one `bulk_transfers` row per `(bank_account_id, idempotency_key)`, and a replay changes nothing.
6. **No double spend:** concurrent bulks on one account never jointly exceed the balance.
7. **Rejections are side-effect free:** any 4xx or 5xx leaves the balance, transaction count and bulk count unchanged.
8. **No floats** anywhere on the money path. Debits are negative, `amount_cents <> 0`, currency is `EUR`.

`expect_ledger_invariants!` (spec support) checks 1, 2 and 4 for every account and bulk.

---

## 3. API contract (as implemented)

`POST /transfers/bulk`. Headers: `Content-Type: application/json`, `Idempotency-Key: <1..255 chars>`.

Evaluation order:
1. The header is checked.
2. The body is parsed and validated.
3. The account is looked up and locked.
4. Idempotency is checked.
5. Funds are checked.
6. The bulk is applied.

| Status | Code | When |
|---|---|---|
| 201 | — | Bulk accepted. Body below. |
| 200 | — | Replay (same key and fingerprint). Same body as the original 201. |
| 400 | `invalid_json` | Malformed JSON, or the Content-Type is not JSON |
| 400 | `missing_idempotency_key` | Header absent or blank |
| 400 | `invalid_idempotency_key` | Header longer than 255 characters |
| 422 | `validation_failed` | Any field rule; `details: [{ index?, field, issue }]` |
| 422 | `account_not_found` | No account matches IBAN + BIC |
| 422 | `insufficient_funds` | `details: { required_amount_cents, available_balance_cents }` |
| 422 | `idempotency_key_reused` | Same key, different fingerprint |
| 503 | `service_unavailable` | Lock timeout, deadlock, statement timeout or lost connection. Sends `Retry-After: 1`. |

Success body:
```json
{
  "bulk_transfer": {
    "id": 1,
    "transfer_count": 3,
    "total_amount_cents": 6225150,
    "created_at": "2026-09-28T10:00:00Z",
    "credit_transfers": [
      { "id": 3, "amount_cents": 1450, "amount_currency": "EUR",
        "counterparty_name": "Bip Bip", "counterparty_iban": "EE383680981021245685",
        "counterparty_bic": "CRLYFRPPTOU", "description": "Wonderland/4410" }
    ]
  }
}
```
Error body: `{ "error": { "code": "insufficient_funds", "message": "Insufficient funds", "details": { … } } }`.

Sample expectations with the seeded balance of 10,000,000 cents: `sample1.json` totals 6,225,150 and returns **201**. `sample2.json` totals 10,648,216 and returns **422 insufficient_funds**.

---

## 4. Target layout

```
app/controllers/api/base_controller.rb        # < ActionController::API, error rendering, ParseError → 400
app/controllers/transfers/bulks_controller.rb # thin: header, permit, call op, render
app/operations/bulk_transfers/create.rb        # transaction + lock + idempotency + funds → Result
app/services/ledger.rb                         # debit! (raises); only writer of balance/transactions
app/services/transaction_guard.rb
app/services/amount_parser.rb                  # string → Integer cents or error
app/services/bulk_transfers/request.rb         # value object: parse + collect validation errors
app/services/bulk_transfers/fingerprint.rb
app/presenters/bulk_transfers/presenter.rb     # record → response hash (used by 201 and 200)
app/errors/domain_error.rb (+ subclasses)
app/models/{bank_account,transaction,bulk_transfer}.rb
lib/result.rb, lib/structured_log.rb
docs/decisions/*.md, CLAUDE.md, README.md
spec/{requests,operations,services,models,lib,errors,concurrency,support,factories,fixtures/files}
```
The exact paths may change in the step that creates them, as long as they follow the checklist's layering.

---

## 5. Starting setup — target configuration

These are the end states that steps 1–5 produce.

**Gemfile additions** (`group :development, :test` unless noted): `rspec-rails`, `factory_bot_rails`, `rubocop`, `rubocop-rails`, `rubocop-rspec`, `rubocop-performance`, `rubocop-factory_bot`, `brakeman`, `bundler-audit`. In `group :test`: `database_cleaner-active_record`. All with `require: false` except rspec-rails and factory_bot_rails.

**`.rubocop.yml`**: already provided by the user and it is **the baseline**. Keep its relaxations (e.g. `Metrics/AbcSize` max 20, double-quoted strings). Only two changes are agreed: add the `rubocop-factory_bot` plugin, and raise `TargetRubyVersion` from 3.3 to the highest version the installed RuboCop supports (4.0 if possible; add a comment explaining any fallback). Any other change to lint rules requires asking the user.

**`config/database.yml`** (default block)
```yaml
host: <%= ENV.fetch("DATABASE_HOST", "localhost") %>
port: <%= ENV.fetch("DATABASE_PORT", 5432) %>
username: <%= ENV.fetch("DATABASE_USER", "postgres") %>
password: <%= ENV.fetch("DATABASE_PASSWORD", "postgres") %>
max_connections: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
variables:
  lock_timeout: <%= ENV.fetch("DB_LOCK_TIMEOUT", "2s") %>
  statement_timeout: <%= ENV.fetch("DB_STATEMENT_TIMEOUT", "10s") %>
```
`development.database: qonto_development`. `test.database: qonto_test`, and `test.max_connections: 15` for the concurrency threads. Production keeps its block.

**`compose.yml`:** `postgres:17-alpine`; remove `DATABASE_NAME`. Everything else stays. Note: changing the major version requires `docker compose down -v` on existing volumes, and the README must say so.

**RSpec** (`rails g rspec:install`):
- `spec/rails_helper.rb` forces `ENV["RAILS_ENV"] = "test"` (assignment, not `||=`), because compose exports development.
- `spec/support/**/*.rb` is autoloaded.
- `config.include FactoryBot::Syntax::Methods`.
- `spec/support/database_cleaner.rb`: for groups tagged `:concurrency`, it sets `self.use_transactional_tests = false` and truncates all tables after each example (`except: ar_internal_metadata, schema_migrations`).
- `.rspec` has `--require rails_helper`.

**`config/ci.rb`**
```ruby
CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn"
  step "Tests: Prepare DB", "env RAILS_ENV=test bin/rails db:prepare"
  step "Tests: RSpec", "env RAILS_ENV=test bin/rspec"
end
```
Binstubs are created for `rubocop`, `brakeman`, `bundler-audit` and `rspec` (`bundle binstubs …` or the generator's).

---

## 6. Implementation steps

Each step ends with `docker compose exec web bin/ci` green (from step 5 onwards; steps 1–4 run their own tool). Commit subjects are given per step.

### Setup

- [x] **1. Commit the untouched scaffold.** Verify `challenge/` and `config/master.key` are ignored. Stage the scaffold files explicitly.
  Commit: `Add Rails 8.1 application scaffold`
- [x] **2. Database and compose config.** The user has already updated `compose.yml` (Postgres 17, DATABASE_* env) and `database.yml` (env host/creds, fixed names, timeouts). **Double-check** them against §5, and align the remaining gaps: `lock_timeout` 5s → `2s` default, ENV overrides `DB_LOCK_TIMEOUT`/`DB_STATEMENT_TIMEOUT`, `test.max_connections: 15`, and no `DATABASE_NAME` left in compose. Verify with `docker compose exec web bin/rails db:prepare` for development and test, and `bin/rails runner 'p ActiveRecord::Base.connection.select_value("SHOW lock_timeout")'` → `"2s"`.
  Commit: `Configure database from env and bump Postgres to 17`
- [x] **3. RuboCop.** Add the gems and the binstub. Apply the two agreed edits to the user's `.rubocop.yml` (§5), and don't make any others.
  Commits:
  1. `Add RuboCop with rails, rspec and performance plugins` (Gemfile, lock, config, binstub)
  2. `Apply RuboCop autocorrections to scaffold` (only the `-a` changes, and `bin/rubocop` must end with no offenses)
- [x] **4. Security scanners.** Add `brakeman` and `bundler-audit` with binstubs. Both pass on the scaffold.
  Commit: `Add Brakeman and bundler-audit`
- [x] **5. RSpec and bin/ci.** Add rspec-rails, factory_bot_rails, database_cleaner-active_record; run `rails g rspec:install`; add the support files from §5; `config/ci.rb` from §5. Add one smoke spec, `spec/lib/test_environment_spec.rb`, asserting `Rails.env.test?` and that the `lock_timeout` setting is applied. `bin/ci` is green.
  Commits:
  1. `Add RSpec, FactoryBot and DatabaseCleaner`
  2. `Run lint, security and specs from bin/ci`
- [x] **6. Repo `CLAUDE.md`.** Distill the engineering checklist (layering, naming, style, testing rules) plus §0 of this plan (commands, commit rules, working on `main`). **Must include this rule:** if any lint rule or convention proves too strict, or agents would work better another way, do not silently disable or work around it. Ask the user to re-evaluate that rule (inline `rubocop:disable` only where a decision explicitly calls for it, like `insert_all`). Keep it under about 120 lines.
  Commit: `Add agent conventions in CLAUDE.md`
- [x] **7. Decision records.** Write all 22 records from §1 in `docs/decisions/`. Each **Context** section explains the underlying problem: the race, the crash window, the conflicting spec text and so on. Each is written for a reviewer who hasn't read the brief. Docs only.
  Commit: `Add decision records for bulk transfer design`

### Domain

- [x] **8. Schema and models.** Migrations for `bank_accounts`, `transactions` and `bulk_transfers` with every constraint and index from decision 7. Models contain only associations, validations and constants (`Transaction::CURRENCY = "EUR"`, `NAME_MAX_LENGTH = 70`, `DESCRIPTION_MAX_LENGTH = 140`). Factories. Model specs prove each DB constraint by writing past the validations (`update_column` / `insert`) and expecting `ActiveRecord::StatementInvalid`/`CheckViolation`.
  Commit: `Add bank account, transaction and bulk transfer schema`
- [x] **9. Seeds.** Hardcode account 1 (ACME Corp, 10,000,000 cents, `FR10474608000002006107XXXXX` / `OIVUSCLQXXX`) and the two transactions (ids 1 and 2, verbatim from the sqlite file). Use `insert_all` with on-conflict-do-nothing, then `reset_pk_sequence!` on each table. Spec: seeding creates the rows, seeding twice is a no-op (a pre-debited balance is untouched), invariant 2 holds, and the next insert gets id 3.
  Commit: `Seed the sample Qonto account and transactions`
- [x] **10. `Result`.** Class methods `success(value, idempotent_replay: false)` / `failure(error)`; instance methods `successful?`, `failed?`, `value`, `errors`, `idempotent_replay?`; frozen. Unit spec.
  Commit: `Add Result value object`
- [x] **11. Domain errors.** A `DomainError` with `configure`, `code`, `http_status`, `message`, `details` and `to_h`. Subclasses: `ValidationFailedError`, `AccountNotFoundError`, `InsufficientFundsError`, `IdempotencyKeyReusedError`, `MissingIdempotencyKeyError`, `InvalidIdempotencyKeyError`, `InvalidJsonError`, `ServiceUnavailableError`. Unit spec per contract line.
  Commit: `Add domain error hierarchy`
- [x] **12. `StructuredLog`.** `StructuredLog.info(event, **fields)` → `event=… k=v` on one line; values are quoted when they contain spaces. Unit spec.
  Commit: `Add StructuredLog formatter`
- [x] **13. `AmountParser`.** Implements decision 5. Table-driven spec covering `"14.5"`→1450, `"61238"`→6123800, `"1.500"`→150, `".5"`→50, `"0"`, `"-1"`, `"1.234"`, `"1e3"`, `" 12"`, `"NaN"`, `"Infinity"`, `"1.2.3"`, `""`, Integer `12`, Float `12.5`, nil, and over-max. No Float appears anywhere in the implementation.
  Commit: `Add amount parser for decimal euro strings`
- [x] **14. `BulkTransfers::Request`.** Builds an immutable value object from permitted params, or collects every validation error (decision 10). Uses `AmountParser`. Unit spec for every rule, including multiple errors across items and a non-object body.
  Commit: `Add bulk transfer request parsing and validation`
- [x] **15. `BulkTransfers::Fingerprint`.** Canonical JSON (sorted keys, preserved array order) → SHA-256 hex. Spec: key order and unknown fields don't matter; item order, amount string and any field value do.
  Commit: `Add request fingerprint`
- [x] **16. `TransactionGuard` + `Ledger.debit!`.** The guard raises unless `ActiveRecord::Base.connection.transaction_open?`. `Ledger.debit!(account:, bulk_transfer:, credit_transfers:)` inserts the negative rows with `insert_all` and a `returning: :id` (inline rubocop disable plus a why comment), then decrements the balance with a guarded SQL update: `UPDATE … SET balance_cents = balance_cents - :total WHERE id = :id AND balance_cents >= :total`, checking `updated_rows`. If zero rows are updated it raises `InsufficientFundsError` (defence in depth; the operation checks first under the lock, and the DB CHECK is the third layer). Never write a Ruby-computed balance. The debit happens before the insert so a failure writes nothing. Adds `spec/support/ledger_invariants.rb` (`expect_ledger_invariants!`). Specs: raises outside a transaction; writes N rows plus the balance; invariants hold.
  Commit: `Add Ledger as the only writer of balances`
- [x] **17. `BulkTransfers::Create` operation.** `transaction(requires_new: true)`; `BankAccount.lock.find_by(iban:, bic:)`; idempotency lookup (same fingerprint → `Result.success(bulk, idempotent_replay: true)`, different fingerprint → failure); funds check; create the bulk row; `Ledger.debit!`. Rescue `DomainError` → failure. Rescue infrastructure errors (decision 13) → `ServiceUnavailableError`. Rescue `RecordNotUnique` on the bulk insert → re-read and replay or reject (with a comment explaining that it's a backstop that can't be reached while the lock holds). Log every outcome with `duration_ms`. Operation specs: success, replay, key reuse, unknown account, insufficient funds (with details), exact-balance success, and a 503 via a real lock held by another connection with `DB_LOCK_TIMEOUT` set short. Every failure asserts nothing changed, and every spec calls `expect_ledger_invariants!`.
  Commit: `Add BulkTransfers::Create operation`
- [x] **18. Endpoint.** Route `POST /transfers/bulk`. `Api::BaseController` (rescue `ActionDispatch::Http::Parameters::ParseError` → 400, render `DomainError#to_h` with its status, and set `Retry-After` on 503). The controller checks the header, permits the fields, calls the operation and renders via `BulkTransfers::Presenter` (201, or 200 on replay). Copy `challenge/sample1.json` and `sample2.json` to `spec/fixtures/files/`. Request specs cover every row in §3, including both samples, a JSON number amount, a wrong Content-Type, unknown fields ignored, and replay body equality.
  Commits:
  1. `Add sample bulk requests as spec fixtures`
  2. `Add POST /transfers/bulk endpoint`
- [x] **19. Concurrency specs** (`:concurrency`, real threads, each thread with its own connection via `ActiveRecord::Base.connection_pool.with_connection`):
  - (a) Two bulks that each fit alone but not together → exactly one success and one `insufficient_funds`.
  - (b) N parallel requests with the same key and body → one 201-equivalent, N−1 replays, and one set of rows.
  - (c) Same key, different bodies in parallel → one success, the rest `idempotency_key_reused`.
  - (d) Bulks on different accounts don't block each other.
  - Invariants are checked after every scenario. Use a start barrier (`Queue`/`CountDownLatch`-style) so the requests really overlap.
  Commit: `Add concurrency specs for double spend and idempotency`
- [x] **20. README.** Write it **outside-in**: start from the problem in plain words, move to the product solution (what a client sees), and only then go into technical detail. Each section should make sense to a reader who stops there. Near the top, a one-line pointer: "Just want to run it? → [Run it](#run-it)". Section order:
  1. **The challenge.** Why bulk transfers exist (payroll for hundreds of employees), what the service must do (accept or reject the whole bulk against the balance), and the hard parts the brief calls out: never lose a cent, several load-balanced instances, crashes and network glitches anywhere, and never accept or refuse a bulk wrongly.
  2. **The solution from the client's point of view.** One `POST /transfers/bulk`, and all-or-nothing semantics. Retries are safe thanks to the `Idempotency-Key`. What each answer means for the client (201 created, 200 replay, 400, 422 with the reasons, 503 retry). The 201 vs 204 discrepancy in the brief and why we chose 201 with a body. Amounts as decimal euro strings.
  3. **Run it.** Setup (`docker compose run --rm web bin/setup`, `docker compose up`, and `down -v` when upgrading from an old Postgres volume). A curl walkthrough: sample1 → 201, the same request again → 200, sample2 → 422, then every error code.
  4. **How it works.** The request lifecycle step by step. The single database transaction that prevents double spends (with the SQL sequence), how idempotency works under the lock, and how money is represented.
  5. **Guarantees.** The invariants from §2 in plain words, and which specs prove each one.
  6. **Operational scenarios.** Crash before commit, crash after commit but before the response, client disconnect, concurrent requests on one account, several instances, lost DB, and retries.
  7. **Architecture and code map.** Layers (controller → operation → Ledger → models), error model, Result, logging, and where each piece lives.
  8. **Development.** `bin/ci`, running specs and lint in the container, test strategy (diamond, concurrency specs), and the conventions in `CLAUDE.md`.
  9. **Scaling and observability.** 10k/s, sharding by account, very large bulks → async with a 202 and a job, a bulk size cap, and metrics and tracing on top of the log events.
  10. **Issues faced.**
  11. **Not built yet** (§7), including the recommendation to use `ibandit` for real IBAN/BIC validation.
  12. **Decision records.** An index linking every `docs/decisions/*.md`.
  Commit: `Add README with challenge, solution and technical guide`
- [x] **21. Final review.** Run `/code-review` on the whole history, and fix findings in separate commits. Check that every invariant in §2 is referenced by at least one spec, and that every decision is referenced where it's implemented.

---

## 7. Not built yet (deliberately)

- Real IBAN/BIC validation (mod-97, BIC directory). Use `ibandit`.
- A bulk size cap, and asynchronous processing (202 + job + status endpoint) for very large bulks.
- Idempotency key expiry and cleanup (a TTL job).
- Authentication and authorisation (anyone can debit any account by IBAN+BIC).
- Actually executing the transfers (SEPA submission, outbox/events to downstream systems).
- Multi-currency.
- A load-balanced multi-instance demo in compose (nginx + replicas).
- Metrics and tracing (Prometheus, OpenTelemetry). Only structured logs exist.
- A periodic reconciliation job that asserts invariant 2 in production.
- Rate limiting.
