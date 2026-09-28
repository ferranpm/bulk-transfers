# 6. Denormalized balance with a movement log

Status: Accepted (2026-09-28)

## Context

The provided schema has `bank_accounts.balance_cents` and a `transactions` table where debits are negative and
credits positive. The seeded rows already add up: 11,000,000 − 1,000,000 = 10,000,000, which is the account's
balance. Two sources of truth for the same number can drift apart. The balance could be updated while the
transaction insert fails, or the reverse, and then a cent is "lost" or created.

Every bulk needs a funds check. That check has to be fast and has to happen under a lock (decision 8).

## Chosen

- `bank_accounts.balance_cents` stays the value the funds check reads.
- `transactions` is an **append-only movements log**, written **in the same database transaction** as the
  balance update. Debits are negative.
- Invariant: for every account, `balance_cents == SUM(transactions.amount_cents)`.

## Discarded (why)

- **Compute the balance from `SUM(amount_cents)` on every request**: O(n) in the account's history for every
  check, and a lock is still needed to stop two requests from both passing the check.
- **Event sourcing**: out of scope for one endpoint.

## Consequences

- Atomicity is what keeps the two in sync. Both writes happen inside one transaction, inside `Ledger`, which is
  the only code allowed to write either (decision 15).
- Specs assert the invariant after every money-touching example (`expect_ledger_invariants!`).
- A periodic reconciliation job that checks the invariant in production is listed under "Not built yet".
