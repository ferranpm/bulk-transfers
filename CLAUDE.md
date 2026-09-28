# CLAUDE.md: conventions for this repository

A Rails 8.1 / Ruby 4.0 / PostgreSQL 17 service that exposes `POST /transfers/bulk`: an all-or-nothing debit
of many credit transfers from one account, safe across several instances, crashes and retries.
The design is recorded in `docs/decisions/` (one file per decision). Read the records a task touches before changing code.

## Commands (everything runs inside the web container)

The `db` and `web` compose services are already running. Never run Ruby tooling on the host.

- **Validity gate, the only command you need:** `docker compose exec web bin/ci`
  (setup, RuboCop, bundler-audit, Brakeman, test DB prepare, RSpec). A change is done only when it is green.
- Ad-hoc: `docker compose exec web bin/rspec spec/path_spec.rb`, `docker compose exec web bin/rubocop -a`
- After changing the Gemfile: `docker compose exec web bundle install`

## Workflow

- Red/green TDD for every behaviour change: write the failing spec, watch it fail for the right reason,
  implement, get to green, then run `bin/ci`.
- One commit per logical step. Imperative subject under 72 characters (`Add Ledger as the only writer of balances`).
- Kinds of change never share a commit: lint autocorrect, config, docs, renames and behaviour are separate.
- Work happens on `main` (explicit decision for this repo; see the `git-workflow` record).
- Stage files explicitly with `git add <path>`. Never `git add .`, `-A` or `-a`.
- Before committing, check `git branch --show-current` and `git diff --cached --stat`, and make sure no secrets
  are staged (`config/master.key`, `config/credentials/*.key`, `.env*`).
- End every commit message with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Don't over-engineer. Anything deliberately left out goes in the README's "Not built yet" section.
- Don't add a gem for something that fits in about 20 lines (`Result`, structured logging, fingerprinting).
- If a task shows that a recorded decision is wrong, **stop and ask the user**. If they agree, amend the decision
  record in its own docs commit.

## When a rule gets in the way: ask, don't bypass

If a RuboCop rule or any convention in this file proves too strict, or you believe agents would work better
another way, **do not silently disable it, loosen `.rubocop.yml`, or work around it.** Stop and ask the user to
re-evaluate that rule, explaining the concrete case. Inline `# rubocop:disable` is allowed only where a decision
record explicitly calls for it (e.g. `insert_all` in the Ledger, decision `bulk-insert-strategy`), always with a
comment explaining why.

## Architecture and layering

- **Controllers are thin**: parse HTTP input, call one operation, render. No business rules. API controllers
  inherit from `Api::BaseController < ActionController::API` (no CSRF, sessions or cookies).
- **Operations** live in `app/operations/<domain>/<verb>.rb` (e.g. `BulkTransfers::Create`):
  - `self.call(**kwargs)` delegates to `new(**kwargs).call`.
  - They **always return a `Result`** and never raise to the caller.
  - They own the transaction boundary (`transaction(requires_new: true)`) and the row lock.
  - They rescue `DomainError` into `Result.failure(error)`, and infrastructure errors (lock timeout, deadlock,
    statement timeout, lost connection) into `Result.failure(ServiceUnavailableError.new)`.
- **Inner domain services raise; they don't return Results** (e.g. `Ledger`). The raise is what rolls the
  transaction back; an unchecked failure Result inside a transaction could commit inconsistent state.
- Inner services that need a transaction call `TransactionGuard.ensure_transaction!` instead of opening one.
- **All money mutations go through `Ledger`.** Nothing else touches `balance_cents` or writes `transactions` rows.
- Exactly one lock per operation: `SELECT ... FOR UPDATE` on the bank account row. A future second lock must
  follow a fixed, documented order. No application-level mutexes; assume several instances.
- Models hold associations, validations and constants only. **No callbacks** that move money or have side effects.
- `Result` is hand-rolled and frozen: `success`, `failure`, `successful?`, `failed?`, `value`, `errors`,
  `idempotent_replay?`. No dry-monads, Interactor or Trailblazer.
- Prefer a functional style: immutable value objects, `module_function` modules, pure helpers, endless one-line
  methods (`def successful? = errors.empty?`). Go procedural when a sequence of steps inside a transaction reads
  more clearly that way.
- Money is `bigint` cents in the DB and Integer cents in Ruby. **Never a Float** on the money path.

## Naming and code style

- Every Ruby file starts with `# frozen_string_literal: true`.
- Descriptive names, no abbreviations (`total_amount_cents`, `updated_rows`, not `tot`, `n`). Block variables are
  named too (`|credit_transfer|`, not `|t|`).
- Error classes end in `Error`, live in `app/errors/` under `DomainError`, and declare their contract in one line:
  `configure code: "insufficient_funds", http_status: :unprocessable_content, default_message: "Insufficient funds"`.
  A `DomainError` carries `code`, `http_status`, `message`, `details` and renders the API body via `to_h`.
- Domain vocabulary lives in constants (`Transaction::CURRENCY`). No scattered magic strings or numbers.
- Comments explain **why** (a contract, an invariant, a sign convention, the reason for a lock) and may cite a
  decision slug. Never comment what the code does.
- Classes that carry a contract get a short header comment with a usage line, e.g.
  `#   BulkTransfers::Create.call(organization_iban:, organization_bic:, credit_transfers:, idempotency_key:) # => Result`

## Linting

- RuboCop with the rails, rspec, performance and factory_bot plugins and `NewCops: enable`, configured in
  `.rubocop.yml`. That file is owned by the user: don't edit it without asking (see "ask, don't bypass").
- `bin/rubocop` must report no offenses. Use `-a` for autocorrect, and keep autocorrect-only changes in their own commit.

## Testing

- RSpec + FactoryBot, diamond-shaped:
  - **Request specs are the largest layer**: every status code and error code, including the sample requests
    in `spec/fixtures/files/`.
  - **Unit specs** for branchy rules: amount parsing, Ledger, `Result`, error classes, fingerprint, log formatter.
  - **Operation specs** assert the result, the balance and the transaction rows together.
  - **Concurrency specs** use real threads against the real database, tagged `:concurrency` (a symbol tag, not
    `concurrency: true`). The tag turns off transactional tests and truncates afterwards
    (`spec/support/database_cleaner.rb`). Each thread checks out its own connection.
- Money-touching specs call the shared `expect_ledger_invariants!` helper (non-negative balance,
  balance equals the sum of transactions, and bulk counts and totals match their rows).
- Every failure-path spec asserts that **nothing changed**: balance, transaction count and bulk count.
- Arrange, Act, Assert separated by blank lines, **without** section comments.
- Name spec files after the behaviour under test; `describe`/`context` blocks read as scenarios.
- Test against the real database. **Never mock the DB or locks.**
- `spec/rails_helper.rb` forces `RAILS_ENV=test`, because compose exports `development`.
- The test pool (`max_connections: 15`) serves concurrency threads; use `DB_LOCK_TIMEOUT` for short lock waits.
