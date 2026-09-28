# 13. Timeouts and unavailability

Status: Accepted (2026-09-28)

## Context

With a pessimistic lock (decision 8), a request for a busy account waits for the lock. PostgreSQL's default
`lock_timeout` is 0, meaning wait forever. A stuck transaction, or a huge bulk, would pile up waiting
requests, exhaust the connection pool and web threads, and turn one slow account into an outage for all
accounts. The database can also disappear (failover, network partition), and deadlocks are always possible in
principle.

All of these are transient: nothing was applied, and because requests are idempotent (decision 9) the client
can safely retry.

## Chosen

- `config/database.yml` sets session `variables`:
  - `lock_timeout`, default **`2s`**, overridable with `DB_LOCK_TIMEOUT`.
  - `statement_timeout`, default **`10s`**, overridable with `DB_STATEMENT_TIMEOUT`.
  Specs use the ENV overrides to prove the behaviour with short waits.
- `ActiveRecord::LockWaitTimeout`, `Deadlocked`, `QueryCanceled`, `ConnectionNotEstablished` /
  `ConnectionFailed` and `ConnectionTimeoutError` → **503 `service_unavailable`** with `Retry-After: 1`.

## Discarded (why)

- **5s lock / 30s statement timeouts**: slower failure under contention. The client has to retry anyway, so
  holding its connection longer only costs capacity.
- **No `Retry-After`**: clients would have to guess a backoff.

## Consequences

- A request waiting longer than 2 s for the account lock fails fast with 503 and nothing applied.
- A bulk whose insert takes over 10 s is cancelled and rolled back. This effectively caps bulk size at
  whatever fits in 10 s, which the README documents.
- The timeouts apply to every query on the connection, including migrations run through the app. Long
  migrations must override them locally.
