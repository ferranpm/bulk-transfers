# 7. Schema changes

Status: Accepted (2026-09-28)

## Context

The brief's schema has `bank_accounts` and `transactions` with integer ids, no timestamps and no constraints.
Application-level validations only protect code paths that go through them: `insert_all`, raw SQL, a console
session or a future bug can bypass them. For money, the database has to be the last line of defence.

The service also needs somewhere to record each accepted bulk and its idempotency key (decision 9), and a way
to link transactions back to the bulk that created them.

## Chosen

- Keep the provided table and column names. Use Rails defaults: `bigint` ids and `created_at`/`updated_at` on
  every table.
- New `bulk_transfers` table: `bank_account_id`, `idempotency_key`, `request_fingerprint`, `transfer_count`,
  `total_amount_cents`.
- `transactions.bulk_transfer_id`: a nullable foreign key, because the seeded rows belong to no bulk.
- Constraints:
  - `CHECK (balance_cents >= 0)`
  - `CHECK (amount_cents <> 0)`
  - `CHECK (amount_currency = 'EUR')`
  - `CHECK (char_length(counterparty_name) <= 70)` and `CHECK (char_length(description) <= 140)`
  - `NOT NULL` wherever the contract requires a value
  - foreign keys
  - `UNIQUE (iban, bic)` on `bank_accounts`
  - `UNIQUE (bank_account_id, idempotency_key)` on `bulk_transfers`
  - indexes on `transactions (bank_account_id)` and `transactions (bulk_transfer_id)`

## Discarded (why)

- **Integer ids and no timestamps** (a strict copy of the sample): no audit trail, and 32-bit ids on an
  append-only log.
- **A separate `idempotency_keys` table storing response snapshots**: more generic, but the bulk row and its
  transactions already hold everything needed to rebuild the response (decision 2).

## Consequences

- Invariants 1 (non-negative balance) and 8 (non-zero EUR amounts) hold even if application code is bypassed.
  Model specs prove each constraint by writing past the validations.
- The 70/140 limits follow SEPA field limits for name and remittance information.
