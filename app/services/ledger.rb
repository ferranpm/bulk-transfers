# frozen_string_literal: true

# The only writer of bank_accounts.balance_cents and of transactions rows, so "where can money move?" has one
# answer (PLAN operations-and-result). It raises instead of returning a Result: the raise is what rolls the
# caller's transaction back. Debits are stored negative (PLAN denormalized-balance-with-movement-log).
#   Ledger.debit!(account:, bulk_transfer:, credit_transfers:) # => inserted transaction ids, in request order
module Ledger
  module_function

  def debit!(account:, bulk_transfer:, credit_transfers:)
    TransactionGuard.ensure_transaction!
    raise ArgumentError, "a debit needs at least one credit transfer" if credit_transfers.empty?

    # Balance first: if it's refused, nothing has been written yet.
    decrement_balance!(account, credit_transfers.sum(&:amount_cents))
    insert_debits!(account, bulk_transfer, credit_transfers)
  end

  def decrement_balance!(account, total_amount_cents)
    # Decrementing in SQL means the balance is never computed in Ruby, and the WHERE clause refuses an overdraft
    # even if a caller forgot the account lock. It is the second of three layers: the operation checks funds under
    # the lock first, and the CHECK (balance_cents >= 0) constraint is the last one. update_all skips validations
    # and callbacks on purpose: the model has none that apply to a balance move (PLAN bulk-insert-strategy).
    updated_rows = BankAccount
                   .where(id: account.id, balance_cents: total_amount_cents..)
                   .update_all(["balance_cents = balance_cents - ?, updated_at = ?", total_amount_cents, Time.current]) # rubocop:disable Rails/SkipsModelValidations
    return if updated_rows == 1

    raise InsufficientFundsError.new(
      details: { required_amount_cents: total_amount_cents, available_balance_cents: account.balance_cents }
    )
  end

  def insert_debits!(account, bulk_transfer, credit_transfers)
    rows = credit_transfers.map do |credit_transfer|
      {
        bank_account_id: account.id,
        bulk_transfer_id: bulk_transfer.id,
        amount_cents: -credit_transfer.amount_cents,
        amount_currency: Transaction::CURRENCY,
        counterparty_name: credit_transfer.counterparty_name,
        counterparty_iban: credit_transfer.counterparty_iban,
        counterparty_bic: credit_transfer.counterparty_bic,
        description: credit_transfer.description
      }
    end

    # One statement for the whole bulk while the account lock is held, instead of N create! round trips; the
    # request was validated before the lock and the DB constraints are the backstop (PLAN bulk-insert-strategy).
    # insert_all! (no ON CONFLICT clause) so a row can never be skipped silently. Ids come back in VALUES order,
    # which is request order.
    Transaction.insert_all!(rows, returning: :id).rows.flatten # rubocop:disable Rails/SkipsModelValidations
  end
end
