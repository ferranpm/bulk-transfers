# 8. Pessimistic row lock

Status: Accepted (2026-09-28)

## Context

The service runs as several load-balanced instances sharing one database. Consider two bulks for the same
account, arriving at the same moment on different instances, balance 100 €, each bulk 70 €:

1. Instance A reads the balance: 100 €. 70 ≤ 100, OK.
2. Instance B reads the balance: 100 €. 70 ≤ 100, OK.
3. A writes balance 30 € and inserts its transactions.
4. B writes balance 30 € (or −40 €) and inserts its transactions.

Both are accepted, 140 € left the account, and the balance is wrong. This is a classic read-check-write race.
The same race hits idempotency: two retries of the same request can both see "key not used yet" and both
debit. In-process locks (a Ruby `Mutex`) don't help because the instances don't share memory.

## Chosen

One database transaction at READ COMMITTED, opened with `transaction(requires_new: true)`:

1. `SELECT ... FROM bank_accounts WHERE iban = ? AND bic = ? FOR UPDATE`: the **only** lock the operation takes.
2. Look up the idempotency key for that account.
3. Check funds against the locked balance.
4. Insert the `bulk_transfers` row and all `transactions` rows.
5. Decrement `balance_cents`.
6. Commit, which releases the lock.

A second request for the same account blocks at step 1 until the first commits, then reads the new balance.
Requests for different accounts don't contend.

## Discarded (why)

- **Conditional `UPDATE ... SET balance = balance - total WHERE balance >= total`**: prevents the double spend,
  but doesn't serialise the idempotency check. Two same-key retries would both debit, and we'd rely on
  `RecordNotUnique` plus a re-read to undo it. The funds rule would also live in SQL.
- **Optimistic locking (`lock_version`)**: a hot payroll account under concurrent submissions leads to retry
  storms.
- **SERIALIZABLE isolation**: every transaction needs a retry loop, and predicate locks add overhead.
- **Advisory locks**: a second locking scheme that future code must remember to use.
- **Ruby `Mutex` / Redis lock**: not shared across instances, or extra infrastructure.

## Consequences

- Throughput per account is serialised, which is the intended behaviour for a single balance. The lock is held
  for the length of the insert, so very large bulks hold it longer (see `timeouts-and-unavailability` and
  "Not built yet": bulk cap, async processing).
- A waiting request gives up after `lock_timeout` (decision 13) and returns 503.
- If a second lock is ever added (e.g. a credit to another account), locks must be taken in a fixed order
  (e.g. by account id) to avoid deadlocks.
- `requires_new: true` makes a rollback inside the operation affect only its own savepoint, which keeps
  transactional specs correct.
