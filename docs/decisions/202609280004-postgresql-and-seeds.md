# 4. PostgreSQL and seeds

Status: Accepted (2026-09-28)

## Context

The brief ships `qonto_accounts.sqlite` with one account (ACME Corp, balance 10,000,000 cents, IBAN
`FR10474608000002006107XXXXX`, BIC `OIVUSCLQXXX`) and two transactions: a +11,000,000 treasury income and a
−1,000,000 salary. It allows bringing another database if we provide a way to create and seed it.

The core of the exercise is preventing double spends when several load-balanced instances process requests for
the same account at once. SQLite has a single writer per file and no row-level locks, so it would hide exactly
the problem we have to solve, and it can't be shared between instances over the network.

The seed data also has to survive re-running: if `db:seed` is run again after some bulks were processed,
resetting the balance to 10,000,000 would silently create money.

## Chosen

- **PostgreSQL 17** (`postgres:17-alpine` in compose).
- `db/seeds.rb` **hardcodes** the single account and the two transactions, with their original ids.
- Rows are inserted with `insert_all` and on-conflict-do-nothing, so seeding twice is a no-op and never touches
  a live balance. The primary key sequences are then reset so the next insert gets id 3.

## Discarded (why)

- **Read the sqlite file at seed time**: needs the extra `sqlite3` gem, and depends on a file that isn't part of
  the committed application.
- **Upsert the seed rows**: re-running seeds would overwrite a balance that bulks have since changed.
- **Keep SQLite**: no row locks, and single-writer semantics hide the concurrency problem.

## Consequences

- The seed data is visible in code review, and a spec proves idempotent seeding.
- Upgrading from an older Postgres volume requires `docker compose down -v`. The README says so.
- The seeded data already satisfies the ledger invariant (decision 6): 11,000,000 − 1,000,000 = 10,000,000.
