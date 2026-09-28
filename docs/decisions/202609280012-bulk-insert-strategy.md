# 12. Bulk insert strategy

Status: Accepted (2026-09-28)

## Context

A bulk can contain hundreds or thousands of transfers (there is no cap, per decision 10), and every row is
inserted **while the account row lock is held** (decision 8). Every other request for that account waits for
the whole insert. Inserting row by row with `create!` means N round trips to the database, N model validation
passes and N callbacks, all inside the lock.

The response (decision 1) must list the created transaction ids in request order, so we need the generated ids
back and a reliable way to line them up with request items.

## Chosen

- A single `insert_all!` for all transaction rows with `returning: :id`: one statement, one round trip. The bang
  form has no `ON CONFLICT` clause, so a row can never be skipped silently.
- Validation has already run in the request parser (decision 10), and the DB `CHECK`s and `NOT NULL`s
  (decision 7) are the backstop.
- The balance is decreased with a guarded `update_all` (`balance_cents = balance_cents - :total WHERE id = :id
  AND balance_cents >= :total`), debited **before** the rows are inserted so a refused debit has written nothing.
- Both Ledger calls carry an inline `# rubocop:disable Rails/SkipsModelValidations` with a comment explaining
  why. These are the only places in production code where an inline disable is sanctioned. The cop is excluded
  for `spec/` (constraint specs must write past validations) and `db/seeds.rb`.
- Response items are ordered by `id`. **Assumption:** for a single multi-row `INSERT ... VALUES`, PostgreSQL
  evaluates the `nextval` defaults in `VALUES` order, so ids ascend in request order. Other sessions may take
  ids in between (leaving gaps), but a sequence only moves forward, so the relative order of our rows holds.

## Discarded (why)

- **`create!` per row**: N round trips while holding the account lock, which matters because there is no bulk
  cap.
- **Raw SQL via `connection.update` for the balance**: avoids the cop warning, but only by hiding the bypass; the
  query builder plus an explicit, justified disable is more honest and idiomatic.
- **`account.update!(balance_cents: account.balance_cents - total)`**: writes a Ruby-computed balance, which
  would silently overwrite a concurrent change if the lock were ever lost.

## Consequences

- Model validations and callbacks don't run for these rows, so models must never rely on callbacks (they
  don't; see decision 15).
- If the ordering assumption ever needs to be removed, store an explicit `position` column per transaction.
- Extremely large bulks still produce one large statement. `statement_timeout` (decision 13) bounds it.
