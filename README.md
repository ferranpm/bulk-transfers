# Bulk transfers service

A web service that lets a Qonto customer submit many credit transfers in one request and applies them **all
or none** against the account balance. It's built with Rails 8.1 and PostgreSQL 17.

Every choice below has a decision record in [`docs/decisions/`](docs/decisions/) with its context, the
alternatives that were rejected, and why. The *Why* links at the end of each section point to the relevant
records.

## 1. What it does

Large organisations pay hundreds of salaries at the end of the month in one bulk request. The service applies
the whole bulk if the account can cover it, and refuses the whole bulk if it can't. The hard part is doing it
safely: several load-balanced instances, crashes at any point, and clients that retry.

The client makes one call, `POST /transfers/bulk`, with the JSON body from the challenge's contract and one
addition: an **`Idempotency-Key`** header (any unique string up to 255 characters, such as a UUID). A client
that gets no answer resends the same request with the same key. If the first attempt went through, it gets
the original result back and no money moves twice.

| Status | Meaning |
|---|---|
| **201 Created** | Applied. The body lists the bulk and every created transfer with its id, in request order. |
| **200 OK** | A replay of an applied key with the same body. Same body as the original 201; nothing debited again. |
| **400 Bad Request** | Missing or invalid `Idempotency-Key`, or a body that isn't JSON. |
| **422 Unprocessable Content** | Refused: invalid fields (all listed), unknown account, insufficient funds, or a key reused for a different body. Nothing is stored, so the key can be reused. |
| **503 Service Unavailable** | Transient (account contention, database hiccup). Nothing applied; retry with the same key after `Retry-After`. |

Amounts are decimal strings in euros (`"14.5"`, `"61238"`), positive, with at most two decimals. JSON numbers
are refused, because a float has already lost the exact value, and so are exponent forms like `"2e3"`. The
only currency is `EUR`. Counterparty names are limited to 70 characters and descriptions to 140, matching the
SEPA field limits so every accepted transfer can later be sent on the SEPA rails.

*Why:* [1 Success status and body](docs/decisions/202609280001-api-success-status-and-body.md) ·
[2 Replay response](docs/decisions/202609280002-idempotent-replay-response.md) ·
[10 Request validation](docs/decisions/202609280010-request-validation.md) ·
[14 Error model](docs/decisions/202609280014-error-model.md)

## 2. Run it

Requirements: Docker with Compose.

```sh
docker compose up -d db
docker compose run --rm web bin/setup --skip-server   # gems, database, schema and seed data
docker compose up                                     # API on http://localhost:8083
```

The seed data is the challenge's sample account: **ACME Corp** (`FR10474608000002006107XXXXX` /
`OIVUSCLQXXX`) with **€100,000.00** and its two transactions. To reset it, add `--reset` to the `bin/setup`
command. If an old Postgres volume gets in the way, run `docker compose down -v` first.

**1. Pay a bulk the balance covers.** `sample1.json` totals €62,251.50.

```sh
curl -i localhost:8083/transfers/bulk -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: payroll-2026-09' --data @spec/fixtures/files/sample1.json
```
```json
HTTP/1.1 201 Created
{"bulk_transfer":{"id":1,"transfer_count":3,"total_amount_cents":6225150,"created_at":"…",
 "credit_transfers":[{"id":3,"amount_cents":1450,"amount_currency":"EUR","counterparty_name":"Bip Bip",…}, …]}}
```

**2. Retry it with the same key**, as a client that missed the answer would. You get `200 OK` with the same
body, and the balance doesn't change.

**3. Try a bulk the balance can't cover.** `sample2.json` totals €106,482.16.

```sh
curl -i localhost:8083/transfers/bulk -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: payroll-2026-10' --data @spec/fixtures/files/sample2.json
```
```json
HTTP/1.1 422 Unprocessable Content
{"error":{"code":"insufficient_funds","message":"Insufficient funds",
          "details":{"required_amount_cents":10648216,"available_balance_cents":3774850}}}
```

Every error has this `{ "error": { "code", "message", "details" } }` shape:

| Status | `code` | When |
|---|---|---|
| 400 | `missing_idempotency_key` / `invalid_idempotency_key` | No key, or longer than 255 characters |
| 400 | `invalid_json` | Malformed JSON, or a `Content-Type` other than `application/json` |
| 422 | `validation_failed` | Any field rule. `details` lists every problem as `{ index, field, issue }`. |
| 422 | `account_not_found` | No account matches both IBAN and BIC |
| 422 | `insufficient_funds` | Total above the balance. `details` has both amounts. |
| 422 | `idempotency_key_reused` | Key already used on this account for a different body |
| 503 | `service_unavailable` | Lock not obtained in 2 s, deadlock, timeout or lost connection. `Retry-After: 1`. |

The full list of validation issues is in the [request specs](spec/requests/transfers/bulks_spec.rb) and the
[validation specs](spec/services/bulk_transfers/request_validation_spec.rb).

## 3. How it works

Validation and fingerprinting happen **before** touching the database, so a malformed request adds no
contention. Everything else happens in one transaction, coordinated by **one row lock on the account**,
because PostgreSQL is the only thing every instance shares:

```sql
BEGIN;
  SELECT * FROM bank_accounts WHERE iban = $1 AND bic = $2 FOR UPDATE;   -- others wait here, up to 2 s
  SELECT * FROM bulk_transfers WHERE bank_account_id = $1 AND idempotency_key = $2;
    -- found, same fingerprint → 200 replay; found, different fingerprint → 422; not found → go on
  -- (Ruby) balance >= total, otherwise raise → ROLLBACK → 422 insufficient_funds
  INSERT INTO bulk_transfers (...);
  UPDATE bank_accounts SET balance_cents = balance_cents - $total
   WHERE id = $1 AND balance_cents >= $total;                            -- 0 rows → raise → ROLLBACK
  INSERT INTO transactions (...) VALUES (...), (...), (...);             -- one statement, debits negative
COMMIT;
```

- **The lock serialises check-then-write for one account.** The second request reads the balance and the
  keys *after* the first one commits. Different accounts never wait on each other. It's the only lock
  taken, so two bulks can't deadlock.
- **Three layers stop an overdraft:** the check under the lock, the guarded `UPDATE`, and a
  `CHECK (balance_cents >= 0)` constraint.
- **Idempotency:** the key is stored with the bulk, under `UNIQUE (bank_account_id, idempotency_key)`, so it
  exists only if the bulk was applied. The fingerprint is a SHA-256 of the canonical request, so key order
  or formatting can't make a genuine retry look different.
- **Money** is integer cents in `bigint` columns, never floats. The balance lives on `bank_accounts`, next to
  an append-only log (`transactions`) written in the same transaction, so the balance always equals the sum
  of the log.

```
Transfers::BulksController   thin: header and content-type checks, whitelists fields, renders a Result
  └─► BulkTransfers::Create  owns the transaction and the lock; always returns a Result
        ├─► BulkTransfers::Request / Fingerprint   parse, validate, hash
        └─► Ledger.debit!    the only code that changes a balance or writes transactions
```

Every outcome is logged as one structured line (`bulk_transfer.accepted`, `.rejected`, `.replayed`,
`.unavailable`) with `duration_ms`. IBANs, BICs and request bodies are never logged.

*Why:* [5 Money](docs/decisions/202609280005-money-representation.md) ·
[6 Balance and log](docs/decisions/202609280006-denormalized-balance-with-movement-log.md) ·
[8 Row lock](docs/decisions/202609280008-pessimistic-row-lock.md) (and the rejected alternatives) ·
[9 Idempotency](docs/decisions/202609280009-idempotency-key-and-fingerprint.md) ·
[12 Bulk insert](docs/decisions/202609280012-bulk-insert-strategy.md) ·
[13 Timeouts](docs/decisions/202609280013-timeouts-and-unavailability.md) ·
[15 Operations and Result](docs/decisions/202609280015-operations-and-result.md) ·
[16 Logging](docs/decisions/202609280016-structured-logging.md)

## 4. Guarantees

Each invariant is proven by the test suite against real PostgreSQL. No locks and no database calls are mocked.

| # | Guarantee | Proven by |
|---|---|---|
| 1 | A balance is never negative. | Constraint spec, Ledger spec, `expect_ledger_invariants!` |
| 2 | Balance = sum of the account's transactions. | `expect_ledger_invariants!`, seed spec |
| 3 | A bulk is applied completely or not at all. | Operation and Ledger failure paths |
| 4 | Each bulk's rows match its declared count and total. | `expect_ledger_invariants!` |
| 5 | One key applies at most one bulk per account. | Unique-index spec, replay specs, parallel same-key spec |
| 6 | Concurrent bulks never jointly exceed the balance. | Concurrency spec: two bulks that fit alone, exactly one accepted |
| 7 | Every refusal (400, 422, 503) changes nothing. | Every failure-path spec |
| 8 | No floats on the money path; debits are negative, non-zero and EUR. | Amount parser and constraint specs |

The concurrency specs run real threads on separate connections, released together so the requests
genuinely overlap.

## 5. Operational scenarios

| Scenario | Outcome |
|---|---|
| Crash before `COMMIT` | PostgreSQL rolls everything back. The client retries with the same key and it's processed as new. |
| Crash after `COMMIT`, before responding | The bulk is applied. The retry gets **200** with the original body; nothing is paid twice. |
| Client disconnects mid-request | The server finishes normally. The retry gets 200 or the same refusal. |
| Connection lost during `COMMIT` | Outcome unknown to the server, so it answers 503. The retry with the same key resolves it. |
| Two requests on one account | The second waits on the lock, then sees the first one's result. |
| Lock held longer than 2 s | 503 with `Retry-After: 1`; nothing applied. |
| Several instances, or the database down | Instances are stateless; all coordination is in PostgreSQL. If it's down, every request is a 503 and no money moves. |

## 6. Development

```sh
docker compose exec web bin/ci    # the single gate: RuboCop, bundler-audit, Brakeman, RSpec
```

Tests follow a diamond shape: request specs are the largest layer, with unit specs for branchy rules, and
concurrency specs (`:concurrency` tag) running real threads. Conventions for humans and coding agents are
in [`CLAUDE.md`](CLAUDE.md).

*Why:* [17 Dev environment](docs/decisions/202609280017-dev-environment.md) ·
[18 Quality gate](docs/decisions/202609280018-quality-gate.md) ·
[19 Testing strategy](docs/decisions/202609280019-testing-strategy.md) ·
[21 Agent conventions](docs/decisions/202609280021-agent-conventions.md)

## 7. Issues faced

- **Strong parameters hide type errors.** `permit` silently drops a value of the wrong type, so the client
  would see "missing" instead of the real problem. The controller whitelists the keys itself.
- **Concurrency specs that prove something.** Transactional fixtures hide each thread's writes from the
  others, so race tests would pass vacuously. Those specs commit for real and truncate afterwards.
- **Testing a 503 without mocks.** A second connection holds the real lock, with a short `lock_timeout`.
- **Bulk writes versus the lint rule.** `insert_all!` and `update_all` skip model validations, which RuboCop
  flags. They're kept (row-by-row writes while holding a lock is worse), with a justified inline exception
  and database constraints as the safety net.

## 8. Not built yet

Left out deliberately rather than half-built:

- **Full IBAN/BIC validation.** Today it checks shape only. Production should use a library such as
  [`ibandit`](https://github.com/gocardless/ibandit) (checksum, country lengths, BIC directory).
- **A bulk size cap and asynchronous processing.** Bulks are processed synchronously with no size limit, so
  a very large one holds the account lock for longer, making other requests on that account wait (503 after
  2 s), and it's rolled back if its insert passes the 10 s statement timeout. The fix is a cap, with larger
  bulks accepted as `202` and processed by a job.
- **Idempotency key expiry.**
- **Authentication and authorisation.**
- **Executing the transfers** (SEPA) and publishing events downstream (outbox).
- **Multi-currency.**
- **A multi-instance Compose demo.** The concurrency specs prove correctness across connections instead.
- **Metrics, tracing, rate limiting and a reconciliation job.**
