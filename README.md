# Bulk transfers service

A web service that lets a Qonto customer submit many credit transfers in one request and applies them **all
or none** against the account balance. It's built with Rails 8.1 and PostgreSQL 17.

> Just want to run it? → [Run it](#3-run-it)

## Contents

1. [The challenge](#1-the-challenge)
2. [The solution from the client's point of view](#2-the-solution-from-the-clients-point-of-view)
3. [Run it](#3-run-it)
4. [How it works](#4-how-it-works)
5. [Guarantees](#5-guarantees)
6. [Operational scenarios](#6-operational-scenarios)
7. [Architecture and code map](#7-architecture-and-code-map)
8. [Development](#8-development)
9. [Scaling and observability](#9-scaling-and-observability)
10. [Issues faced](#10-issues-faced)
11. [Not built yet](#11-not-built-yet)
12. [Decision records](#12-decision-records)

---

## 1. The challenge

Some Qonto customers are large organisations. At the end of the month, they pay the salaries of hundreds of
employees. Sending those transfers one by one is slow and error-prone, so they send them **in bulk**: one
request that lists every transfer.

The service receives that request for a single Qonto account and must:

- **accept the whole bulk** if the account can pay for all of it. That means recording every transfer,
  decreasing the balance and confirming,
- or **refuse the whole bulk** if it can't. No partial payroll: either everybody gets paid or nobody does.

That sounds like "compare a sum to a number". The hard part is doing it safely in a real production setting,
as the brief points out:

- **Never lose a cent.** Money can't appear, vanish or be rounded away.
- **Several load-balanced instances.** Two requests for the same account can arrive at two different
  servers at the same moment. If both check the balance before either writes, the account can be overdrawn.
- **Anything can crash at any point.** That includes our server, the database connection, the network and
  the client. A client that doesn't get an answer will retry, and a retry must never pay the salaries twice.
- **No wrong answers in either direction.** Accepting a bulk the balance can't cover is a loss. Refusing one
  it can cover is a failed payroll.

## 2. The solution from the client's point of view

The client makes one call: `POST /transfers/bulk`, with the JSON body defined in the brief's contract.

```http
POST /transfers/bulk
Content-Type: application/json
Idempotency-Key: 2c1f6a8e-6f4b-4a53-9d1a-2b8f0e7c9a10

{ "organization_iban": "...", "organization_bic": "...", "credit_transfers": [ { "amount": "14.5", ... } ] }
```

**All or nothing.** Every transfer in the bulk is recorded and the balance goes down by the total, or nothing
happens at all. The service never records half a bulk.

**Retries are safe.** Every request carries an `Idempotency-Key` header: any unique string up to 255
characters, and a UUID is recommended. If the client doesn't get an answer (a timeout, a dropped connection,
a crash), it resends **the same request with the same key**:

- If the first attempt went through, the retry returns the original result and moves no money.
- If the first attempt didn't go through, the retry is processed as new.

This header is an **addition to the brief's contract**. Without it, the service can't tell "a retry of a
bulk I already paid" apart from "a second, identical payroll".

**What each answer means for the client:**

| Status | Meaning | What the client should do |
|---|---|---|
| **201 Created** | The bulk was applied. The body lists the bulk and every created transfer with its id, in request order. | Done. |
| **200 OK** | This key was already applied with this same body. The body is identical to the original 201. | Done. Nothing was debited twice. |
| **400 Bad Request** | The request isn't usable: missing or invalid `Idempotency-Key`, or a body that isn't JSON. | Fix the request. |
| **422 Unprocessable Content** | The request was understood and **refused**: invalid fields (each problem is listed), unknown account, insufficient funds (with the amounts), or a key already used for a different bulk. | Fix the data or top up the account. A refused bulk is never stored, so the same key can be reused. |
| **503 Service Unavailable** | A transient problem (contention on the account, a database hiccup). Nothing was applied. | Retry with the same key, after `Retry-After` seconds. |

**Amounts** are decimal strings in euros, as in the contract: `"14.5"`, `"61238"` or `"999.99"`. They must
be positive with at most two decimals. JSON numbers (`14.5` without quotes) are refused, because once a
client has serialised an amount as a float, its exact value is already uncertain. The only currency is `EUR`.

## 3. Run it

Requirements: Docker with Compose.

```sh
docker compose up -d db
docker compose run --rm web bin/setup --skip-server   # installs gems, creates the DB, loads schema and seed data
docker compose up                                     # API on http://localhost:8083
```

The seed data is the account from the brief's `qonto_accounts.sqlite`: **ACME Corp**, IBAN
`FR10474608000002006107XXXXX`, BIC `OIVUSCLQXXX`, with a balance of **€100,000.00** and its two
transactions.

> If you had a volume created by an older Postgres image, run `docker compose down -v` first: Postgres
> can't open a data directory from another major version.
>
> To reset the data after experimenting, run `docker compose run --rm web bin/setup --skip-server --reset`.

### Walkthrough

The two sample requests from the brief are in `spec/fixtures/files/`.

**1. Pay a bulk the balance covers.** `sample1.json` totals €62,251.50.

```sh
curl -i localhost:8083/transfers/bulk \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: payroll-2026-09' \
  --data @spec/fixtures/files/sample1.json
```
```json
HTTP/1.1 201 Created

{"bulk_transfer":{"id":1,"transfer_count":3,"total_amount_cents":6225150,"created_at":"2026-09-28T19:01:10Z",
 "credit_transfers":[
  {"id":3,"amount_cents":1450,"amount_currency":"EUR","counterparty_name":"Bip Bip",
   "counterparty_iban":"EE383680981021245685","counterparty_bic":"CRLYFRPPTOU","description":"Wonderland/4410"},
  {"id":4,"amount_cents":6123800, ...},
  {"id":5,"amount_cents":99900, ...}]}}
```

**2. Retry it, as a client that missed the answer would.** Same key and same body. You get the same body
with a 200, and the balance is untouched.

```sh
curl -i localhost:8083/transfers/bulk \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: payroll-2026-09' \
  --data @spec/fixtures/files/sample1.json
# HTTP/1.1 200 OK  (same body as above)
```

**3. Try a bulk the balance can't cover.** `sample2.json` totals €106,482.16, more than the seeded balance
even before step 1.

```sh
curl -i localhost:8083/transfers/bulk \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: payroll-2026-10' \
  --data @spec/fixtures/files/sample2.json
```
```json
HTTP/1.1 422 Unprocessable Content

{"error":{"code":"insufficient_funds","message":"Insufficient funds",
          "details":{"required_amount_cents":10648216,"available_balance_cents":3774850}}}
```

### Every error

Every error has the same shape: `{ "error": { "code", "message", "details" } }`.

| Status | `code` | Trigger | `details` |
|---|---|---|---|
| 400 | `missing_idempotency_key` | No `Idempotency-Key` header, or a blank one | `null` |
| 400 | `invalid_idempotency_key` | Key longer than 255 characters | `null` |
| 400 | `invalid_json` | Malformed JSON, or a `Content-Type` other than `application/json` | `null` |
| 422 | `validation_failed` | Any field rule (see below). **Every** problem is listed, not only the first. | `[{ "index", "field", "issue" }]` (`index` is only present for items of `credit_transfers`) |
| 422 | `account_not_found` | No account matches both the IBAN and the BIC | `null` |
| 422 | `insufficient_funds` | Bulk total above the balance | `{ "required_amount_cents", "available_balance_cents" }` |
| 422 | `idempotency_key_reused` | Key already used on this account for a **different** body | `null` |
| 503 | `service_unavailable` | Account lock not obtained within 2 s, deadlock, statement timeout, or lost DB connection. Sends `Retry-After: 1`. | `null` |

Validation `issue` values:
- `missing`, `must_be_a_string`, `blank`, `too_long` (name > 70, description > 140), and `invalid_format`
  (IBAN, BIC or amount shape).
- For amounts: `must_be_positive`, `too_many_decimals`, `too_large`.
- `invalid_characters` for a text field containing a NUL character, which PostgreSQL text columns can't store.
- `unsupported_currency` for anything other than `EUR`.
- For the list itself: `must_be_an_array`, `must_not_be_empty`, `must_be_an_object`.

For example:

```sh
curl -s localhost:8083/transfers/bulk -H 'Content-Type: application/json' -H 'Idempotency-Key: k-1' \
  -d '{"organization_iban":"FR10474608000002006107XXXXX","organization_bic":"OIVUSCLQXXX",
       "credit_transfers":[{"amount":14.5,"currency":"USD","counterparty_name":"Bip Bip",
       "counterparty_iban":"EE383680981021245685","counterparty_bic":"nope","description":"x"}]}'
```
```json
{"error":{"code":"validation_failed","message":"The request is invalid","details":[
  {"index":0,"field":"amount","issue":"must_be_a_string"},
  {"index":0,"field":"currency","issue":"unsupported_currency"},
  {"index":0,"field":"counterparty_bic","issue":"invalid_format"}]}}
```

The service checks things in a fixed order, and stops at the first failure: header → body parsing and
validation → account → idempotency → funds.

## 4. How it works

### The request lifecycle

1. **Controller** (`Transfers::BulksController`): it checks the `Idempotency-Key` and the `Content-Type`,
   keeps only the three known top-level fields, calls the operation, and renders its result.
2. **Parsing and validation, before any lock** (`BulkTransfers::Request`): every field is checked and every
   amount becomes integer cents. A malformed request never touches the database or adds contention.
3. **Fingerprint** (`BulkTransfers::Fingerprint`): a SHA-256 of the validated request in canonical JSON
   (sorted keys, transfers in request order, amounts exactly as sent). Formatting or key order can't make a
   genuine retry look like a different request.
4. **One database transaction** (`BulkTransfers::Create`) that does everything else, described next.

### The transaction that prevents a double spend

Two instances can receive a bulk for the same account at the same moment. Each check has to see the other's
effects. The only thing every instance shares is PostgreSQL, so the coordination happens there, with **one
row lock on the bank account**:

```sql
BEGIN;
  -- 1. Lock the account. A concurrent request for the same account waits here, up to lock_timeout = 2s.
  SELECT * FROM bank_accounts WHERE iban = $1 AND bic = $2 LIMIT 1 FOR UPDATE;

  -- 2. Idempotency, under the lock: has this key already been applied on this account?
  SELECT * FROM bulk_transfers WHERE bank_account_id = $1 AND idempotency_key = $2;
  --    found + same fingerprint → return it (200); found + other fingerprint → 422; not found → go on

  -- 3. (Ruby) balance_cents >= total?  otherwise raise → ROLLBACK → 422 insufficient_funds

  -- 4. Record the bulk, then move the money (Ledger)
  INSERT INTO bulk_transfers (bank_account_id, idempotency_key, request_fingerprint, transfer_count, total_amount_cents, ...);
  UPDATE bank_accounts SET balance_cents = balance_cents - $total
   WHERE id = $1 AND balance_cents >= $total;                     -- 0 rows → raise → ROLLBACK
  INSERT INTO transactions (...) VALUES (...), (...), (...) RETURNING id;   -- one statement, debits negative
COMMIT;
```

- **The lock serialises the whole check-then-write** for one account. When the second request gets the lock,
  it reads the balance *after* the first one committed (READ COMMITTED re-reads the locked row), and it sees
  the first one's idempotency key. Requests for **different accounts** never wait on each other.
- **It is the only lock the operation takes**, so a deadlock between two bulks can't happen. If a second lock
  is ever needed, it must always be taken in a fixed order.
- **Three layers stop an overdraft:**
  1. The Ruby check under the lock.
  2. The `WHERE balance_cents >= total` on the update, which still refuses if someone removes the lock by
     mistake.
  3. The `CHECK (balance_cents >= 0)` constraint in the database.
- **Every failure raises**, and the raise rolls the transaction back. Nothing can be left half-written.
- We chose this lock over the alternatives: a conditional update alone, optimistic locking, SERIALIZABLE
  isolation, advisory locks, or an application mutex. See
  [decision 8](docs/decisions/202609280008-pessimistic-row-lock.md) for why each was rejected.

### Idempotency

- The key is stored with the bulk in `bulk_transfers`, with `UNIQUE (bank_account_id, idempotency_key)`, so
  it only exists if the bulk was applied: they are committed together.
- It is looked up **under the account lock**. Two retries racing on different instances are serialised, and
  the second one sees the first one's committed key.
- The unique index is a backstop: if the lock were ever bypassed, the second insert would fail, and the
  request would resolve as a replay or a reuse.
- Refused requests aren't stored. A client that got `insufficient_funds` can top up the account and retry
  with the same key.
- Details: [decision 9](docs/decisions/202609280009-idempotency-key-and-fingerprint.md).

### Money

- Amounts are stored as **integer cents** in `bigint` columns, and are never floats, in the database or in
  Ruby.
- Incoming strings are parsed with `BigDecimal`, behind a character whitelist that refuses `1e3`,
  `Infinity` or whitespace, and are then converted to cents only if they have at most two decimals
  ([decision 5](docs/decisions/202609280005-money-representation.md)).
- The balance is kept on `bank_accounts`, next to an **append-only movements log** (`transactions`). Both
  are written in the same database transaction, and debits are stored as negative amounts. That's why the
  balance always equals the sum of the account's transactions. The seed data already satisfies this: +€110,000
  − €10,000 = €100,000.

## 5. Guarantees

Each of these invariants is checked by the test suite against a real PostgreSQL database. Nothing is mocked:
no locks, no database.

| # | Guarantee | Proven by |
|---|---|---|
| 1 | A balance is never negative. | `CHECK` constraint spec; Ledger refusal spec; `expect_ledger_invariants!` after every money-moving spec |
| 2 | Balance = sum of the account's transactions. | `expect_ledger_invariants!`; seed spec |
| 3 | A bulk is applied completely or not at all. | Operation and Ledger specs (failure paths assert that nothing changed) |
| 4 | Each bulk's rows add up to its declared count and total. | `expect_ledger_invariants!` |
| 5 | One key applies at most one bulk per account, and a replay changes nothing. | Unique-index spec; replay specs; parallel same-key concurrency spec |
| 6 | Concurrent bulks never jointly exceed the balance. | Concurrency spec: two bulks that fit alone but not together → exactly one accepted |
| 7 | Every refusal (400, 422, 503) leaves balance, transactions and bulks unchanged. | Every failure-path request and operation spec |
| 8 | No floats on the money path. Debits are negative, non-zero and EUR. | Amount parser specs; `CHECK` constraint specs |

The concurrency specs use real threads, each on its own database connection, released together from a start
gate so the requests genuinely overlap.

## 6. Operational scenarios

| Scenario | What happens | What the client sees and does |
|---|---|---|
| **Our process crashes before `COMMIT`** | The connection drops, and PostgreSQL rolls back everything in the transaction. Nothing was applied. | A connection error or a 502 from the load balancer. It retries with the same key, and the request is processed as new. |
| **Our process crashes after `COMMIT`, before responding** | The bulk is fully applied and durable. | No answer. It retries with the same key and gets **200** with the original body. Nothing is paid twice. |
| **The client disconnects mid-request** | The server carries on and commits (or refuses) normally. | It retries with the same key and gets 200 (applied) or the same refusal. |
| **The DB connection is lost mid-transaction** | The transaction is aborted on the database side. Rails raises a connection error, which becomes a **503**. | It retries with the same key. |
| **The connection is lost *during* `COMMIT`** | The outcome is genuinely unknown to our process: it may or may not have committed. | A 503. The retry with the same key resolves the ambiguity: 200 if it had committed, a fresh processing if not. |
| **Two requests on one account at the same time** | The second one waits on the account row lock, then sees the first one's result (new balance, or its key). | Both get correct answers. At most one of two bulks that don't both fit is accepted. |
| **The lock is held for longer than 2 s** (a very large bulk in front) | `lock_timeout` fires, and the waiting request becomes a **503** with `Retry-After: 1`. Nothing was applied. | It retries with the same key. |
| **Several instances** | Instances are stateless. All coordination (lock, key, balance) is in PostgreSQL. There are no in-process mutexes and no caches. | Any instance can serve any retry. |
| **The database is down** | Every request is a 503, and no money moves. | It retries with backoff. |

## 7. Architecture and code map

```
HTTP ─► Transfers::BulksController        thin: transport checks, whitelists fields, renders a Result
          │
          ▼
        BulkTransfers::Create              the use case: owns the transaction and the lock, returns a frozen Result,
          │                                never raises to the caller (domain errors → failure, infra errors → 503)
          ├─► BulkTransfers::Request       parse + validate, collect every error (uses AmountParser)
          ├─► BulkTransfers::Fingerprint   canonical JSON → SHA-256
          └─► Ledger.debit!                the ONLY code that changes a balance or writes transactions;
                                           raises (the raise is what rolls back); requires an open transaction
```

| Path | Role |
|---|---|
| `app/controllers/api/base_controller.rb` | `ActionController::API` base: JSON-only, renders every error as the envelope, sets `Retry-After` |
| `app/controllers/transfers/bulks_controller.rb` | The endpoint |
| `app/operations/bulk_transfers/create.rb` | The use case (transaction, lock, idempotency, funds, logging) |
| `app/services/ledger.rb`, `transaction_guard.rb` | Money movement, and the "must be inside a transaction" guard |
| `app/services/amount_parser.rb`, `bulk_transfers/{request,fingerprint}.rb` | Input parsing and fingerprinting |
| `app/presenters/bulk_transfers/presenter.rb` | Builds the 201/200 body from the stored rows, so a replay is byte-for-byte the original |
| `app/errors/` | `DomainError` and its subclasses. Each declares its `code`, HTTP status and message on one line. |
| `app/models/` | Associations, validations and constants only. No callbacks move money. |
| `lib/result.rb`, `lib/structured_log.rb` | A roughly 20-line `Result` value object; one-line `event=… key=value` logs |
| `db/migrate/`, `db/seeds.rb` | Schema with its `CHECK`s, FKs and unique indexes; the brief's sample data |

**Data model.** The brief's `bank_accounts` and `transactions` keep their tables and column names, and gain
timestamps and constraints. A new `bulk_transfers` table holds each accepted bulk (key, fingerprint, count,
total), and `transactions.bulk_transfer_id` links each movement to its bulk. The seeded movements belong to
no bulk.

**Logs.** Every outcome is logged as one line:
- `bulk_transfer.accepted` (account, bulk, count, total, `duration_ms`),
- `.rejected` (reason code),
- `.replayed`,
- `.unavailable`.

IBANs, BICs, request bodies and idempotency keys are never logged, and IBANs and BICs are also filtered out
of the Rails request logs.

**Full Rails stack.** The app keeps the stack the scaffold generated. The API controllers inherit from
`ActionController::API`, so there's no CSRF, cookies or sessions on this endpoint
([decision 3](docs/decisions/202609280003-keep-full-rails-stack.md)).

## 8. Development

Everything runs inside the `web` container, with the `db` container up.

```sh
docker compose exec web bin/ci                                  # the single gate: RuboCop, bundler-audit, Brakeman, RSpec
docker compose exec web bin/rspec spec/requests                 # a subset
docker compose exec web bin/rspec --tag concurrency             # only the multi-threaded specs
docker compose exec web bin/rubocop -a
```

**Tests** follow a diamond shape:
- **Request specs** are the largest layer. They cover every status and every error code, plus both samples.
- **Operation specs** check the result, the balance and the rows together.
- **Unit specs** cover rules with many branches: amount parsing, validation, fingerprinting, the Ledger,
  `Result`, errors and logs.
- **Database constraint specs** write past the model validations to prove each `CHECK`, FK and unique index.
- **Concurrency specs** (tag `:concurrency`) run without transactional fixtures and truncate afterwards.
- The shared `expect_ledger_invariants!` helper runs after every spec that moves money.

**Conventions** for humans and coding agents are in [`CLAUDE.md`](CLAUDE.md): layering, naming, error model,
test style, and commit rules. It includes one rule worth calling out: if a lint rule gets in the way, ask
for it to be re-evaluated rather than working around it.

## 9. Scaling and observability

**Where the limit is.** Bulks for **one account** are processed one at a time. That's what makes them
correct, and it's the right trade-off: a single customer doesn't send thousands of payrolls per second.
Bulks for **different accounts** run in parallel, so throughput grows with instances until PostgreSQL
becomes the bottleneck.

**Towards 10k requests/second:**
- **Connections.** Put PgBouncer in transaction mode in front of PostgreSQL. The service is compatible,
  because it keeps no session state between transactions.
- **Short lock hold time.** Validation and fingerprinting already happen before the lock. The time spent
  inside the lock is two statements plus one multi-row insert.
- **Shard by account.** Every transaction touches exactly one account, so partitioning accounts across
  database clusters (and routing by IBAN) scales writes horizontally with no cross-shard transactions.
- **Idempotency table growth.** Expire keys after a retention window (for example 24–72 h), with a TTL job
  or time-partitioned tables dropped whole.
- **Hot accounts.** For one account with extreme volume, a queue per account (a single consumer serialises
  its bulks) moves the waiting off the database lock.

**Very large bulks** (tens of thousands of lines) shouldn't hold an HTTP request and an account lock for
seconds:
- Cap the synchronous bulk size.
- Above the cap, accept with **202** and a status URL. A job reserves the funds under the lock (one
  statement), then writes the rows in chunks, or with `COPY`.
- The idempotency and invariant design stays the same.

**Observability.** The structured log events are the base layer. Next steps:
- **Metrics:** outcomes by code, `duration_ms` and lock-wait histograms, and the 503 rate as an alert
  signal.
- **Tracing:** OpenTelemetry spans around lock acquisition and the Ledger.
- **Reconciliation:** a periodic job that checks invariant 2 (balance = sum of transactions) in production
  and pages on any drift.

## 10. Issues faced

- **The brief contradicts itself on the success status** (201 in the text, 204 in the OpenAPI block). We
  chose 201 with a body and documented why.
- **Strong parameters hide type errors.** `permit` silently drops a value of the wrong type (a string where
  the transfer list should be), so the client would get "missing" instead of the real problem. The
  controller whitelists the top-level keys itself, and the validator reports the actual type error.
- **Making concurrency specs prove something.** Transactional fixtures wrap each spec in a transaction that
  other threads can't see, which would make race tests pass vacuously. The concurrency specs turn them off,
  give every thread its own connection, and release all threads from a start gate.
- **Testing a 503 without mocks.** The spec holds the account lock on a second connection and shortens the
  wait with `SET LOCAL lock_timeout`, so the real PostgreSQL error travels through the real error mapping.
- **Bulk inserts versus the lint rule.** `insert_all` and `update_all` bypass model validations, which
  RuboCop rightly flags. They're kept (N round trips while holding a lock is worse), with one justified
  inline exception each in the Ledger, and database constraints as the safety net
  ([decision 12](docs/decisions/202609280012-bulk-insert-strategy.md)).
- **Tooling in a slim image.** bundler-audit needs `git` to fetch its advisory database, which the slim
  Ruby image doesn't include, so it was added to the Dockerfile.

## 11. Not built yet

These were left out deliberately, rather than half-built:

- **Real IBAN/BIC validation.** Today it checks presence and shape only. Production should use a dedicated
  library such as [`ibandit`](https://github.com/gocardless/ibandit) (mod-97 checksum, country lengths, BIC
  directory). We didn't use it here because the brief's sample data uses synthetic IBANs that could fail a
  real checksum.
- **A bulk size cap and asynchronous processing** (202 + job + status endpoint) for very large bulks.
- **Idempotency key expiry.**
- **Authentication and authorisation.** Today, anyone who knows an IBAN and BIC can debit that account.
- **Executing the transfers** on the payment rails (SEPA), and publishing events to downstream systems
  (outbox).
- **Multi-currency.**
- **A multi-instance demo** in Compose (a load balancer and replicas). Correctness across instances is
  proven by the concurrency specs instead.
- **Metrics, tracing, rate limiting, and a production reconciliation job.**

## 12. Decision records

Each decision has a record in `docs/decisions/` with its context, the chosen option, the rejected
alternatives and why, and the consequences.

| # | Decision |
|---|---|
| 1 | [API success status and body](docs/decisions/202609280001-api-success-status-and-body.md) |
| 2 | [Idempotent replay response](docs/decisions/202609280002-idempotent-replay-response.md) |
| 3 | [Keep the full Rails stack](docs/decisions/202609280003-keep-full-rails-stack.md) |
| 4 | [PostgreSQL and seeds](docs/decisions/202609280004-postgresql-and-seeds.md) |
| 5 | [Money representation](docs/decisions/202609280005-money-representation.md) |
| 6 | [Denormalized balance with a movement log](docs/decisions/202609280006-denormalized-balance-with-movement-log.md) |
| 7 | [Schema changes](docs/decisions/202609280007-schema-changes.md) |
| 8 | [Pessimistic row lock](docs/decisions/202609280008-pessimistic-row-lock.md) |
| 9 | [Idempotency key and fingerprint](docs/decisions/202609280009-idempotency-key-and-fingerprint.md) |
| 10 | [Request validation](docs/decisions/202609280010-request-validation.md) |
| 11 | [Non-JSON requests](docs/decisions/202609280011-non-json-requests.md) |
| 12 | [Bulk insert strategy](docs/decisions/202609280012-bulk-insert-strategy.md) |
| 13 | [Timeouts and unavailability](docs/decisions/202609280013-timeouts-and-unavailability.md) |
| 14 | [Error model](docs/decisions/202609280014-error-model.md) |
| 15 | [Operations and Result](docs/decisions/202609280015-operations-and-result.md) |
| 16 | [Structured logging](docs/decisions/202609280016-structured-logging.md) |
| 17 | [Development environment](docs/decisions/202609280017-dev-environment.md) |
| 18 | [Quality gate](docs/decisions/202609280018-quality-gate.md) |
| 19 | [Testing strategy](docs/decisions/202609280019-testing-strategy.md) |
| 20 | [Git workflow](docs/decisions/202609280020-git-workflow.md) |
| 21 | [Agent conventions](docs/decisions/202609280021-agent-conventions.md) |
| 22 | [Debrief in the README](docs/decisions/202609280022-debrief-in-readme.md) |
