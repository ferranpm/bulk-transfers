# frozen_string_literal: true

# Invariants 1, 2 and 4 of the plan, checked across every account and bulk in the database
# (PLAN denormalized-balance-with-movement-log).
module LedgerInvariants
  def expect_ledger_invariants!
    transaction_sums_by_account = Transaction.group(:bank_account_id).sum(:amount_cents)
    BankAccount.find_each do |bank_account|
      expect(bank_account.balance_cents).to be >= 0
      expect(bank_account.balance_cents).to eq(transaction_sums_by_account.fetch(bank_account.id, 0))
    end

    transaction_counts_by_bulk = Transaction.where.not(bulk_transfer_id: nil).group(:bulk_transfer_id).count
    transaction_sums_by_bulk = Transaction.where.not(bulk_transfer_id: nil).group(:bulk_transfer_id).sum(:amount_cents)
    BulkTransfer.find_each do |bulk_transfer|
      expect(transaction_counts_by_bulk.fetch(bulk_transfer.id, 0)).to eq(bulk_transfer.transfer_count)
      expect(transaction_sums_by_bulk.fetch(bulk_transfer.id, 0)).to eq(-bulk_transfer.total_amount_cents)
    end
  end
end

RSpec.configure do |config|
  config.include LedgerInvariants
end
