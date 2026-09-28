# 15. Operations and Result

Status: Accepted (2026-09-28)

## Context

Money logic tends to leak into controllers (hard to test and reuse) or into model callbacks (hidden side
effects: saving a record silently moves money). Both make it hard to answer "where can the balance change?",
which is the first question in any money-movement review.

There is also a subtle transaction hazard. If an inner step returns a failure *value* instead of raising, and
the caller forgets to check it, the surrounding transaction commits a half-applied state. Raising is what
triggers a rollback.

## Chosen

- A thin controller calls **one operation**, `BulkTransfers::Create.call(...)`, which **always returns a frozen
  `Result`** (`success` / `failure`, `successful?`, `failed?`, `value`, `errors`, `idempotent_replay?`).
- The operation owns the transaction boundary and the lock, and turns `DomainError`s and infrastructure errors
  into failure Results at its edge.
- **Inner services raise.** `Ledger` is the only writer of `balance_cents` and `transactions`. Services that
  need a transaction call `TransactionGuard.ensure_transaction!` instead of opening one.
- Models hold associations, validations and constants only. No callbacks.
- `Result` is hand-rolled (about 20 lines).

## Discarded (why)

- **dry-monads / Interactor / Trailblazer**: a gem and its idioms for about 20 lines of code.
- **Fat models with callbacks**: hidden money movement.

## Consequences

- "Where can money move?" has one answer: `Ledger`.
- Calling `Ledger.debit!` outside a transaction raises immediately instead of committing partial state.
- Controllers branch only on `Result`, never on exceptions from the domain.
