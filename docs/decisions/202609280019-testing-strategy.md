# 19. Testing strategy

Status: Accepted (2026-09-28)

## Context

The risky behaviours in this service are exactly the ones that are hard to test: two requests racing for the
same balance, retries arriving while the original is still in flight, and partial failures that must leave no
trace. Tests that mock the database or the lock prove nothing about these. Rails' default transactional tests
also hide them: every example runs inside one transaction on one connection, so a second thread can't see its
data and row locks never conflict.

## Chosen

- RSpec + FactoryBot, diamond-shaped:
  - **Request specs are the largest layer**: every status and error code, `sample1.json` → 201,
    `sample2.json` → 422 `insufficient_funds`.
  - **Unit specs** for branchy rules (amount parsing, request validation, fingerprint, `Result`, errors, log
    formatter).
  - **Operation specs** assert the result, the balance and the rows together.
  - **Concurrency specs** (`:concurrency` tag) run real threads, each with its own connection, with
    transactional tests turned off and `database_cleaner-active_record` truncation afterwards.
- A shared `expect_ledger_invariants!` helper checks the balance is non-negative, the balance equals the sum of
  the account's transactions, and every bulk's count and total match its rows.
- Every failure-path spec asserts that **nothing changed** (balance, transaction count, bulk count).
- Arrange, Act, Assert separated by blank lines, without section comments.
- Never mock the DB or locks.

## Discarded (why)

- **Hand-rolled `TRUNCATE`**: the user preferred the widely used gem.
- **Mocking locks**: proves nothing about concurrency.

## Consequences

- The test database pool is sized for the threads (`max_connections: 15`).
- Concurrency specs are slower and must clean up after themselves. The tag is applied to whole groups.
- `spec/rails_helper.rb` forces `RAILS_ENV=test`, because compose exports development.
