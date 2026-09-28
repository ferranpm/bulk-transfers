# frozen_string_literal: true

# The sample account and its two transactions, copied verbatim (ids included) from the brief's
# qonto_accounts.sqlite (PLAN postgresql-and-seeds). Balance 10,000,000 == 11,000,000 - 1,000,000,
# so the ledger invariant holds from the start (PLAN denormalized-balance-with-movement-log).
#
# Re-running must never reset a live balance, so existing rows are left alone rather than upserted.

sample_account_attributes = {
  organization_name: "ACME Corp",
  balance_cents: 10_000_000,
  iban: "FR10474608000002006107XXXXX",
  bic: "OIVUSCLQXXX"
}

sample_transactions_attributes = {
  1 => { counterparty_name: "ACME Corp. Main Account", counterparty_iban: "EE382200221020145685",
         counterparty_bic: "CCOPFRPPXXX", amount_cents: 11_000_000, amount_currency: "EUR", bank_account_id: 1,
         description: "Treasury income" },
  2 => { counterparty_name: "Bip Bip", counterparty_iban: "EE383680981021245685",
         counterparty_bic: "CRLYFRPPTOU", amount_cents: -1_000_000, amount_currency: "EUR", bank_account_id: 1,
         description: "Bip Bip Salary" }
}

ActiveRecord::Base.transaction do
  BankAccount.create_with(sample_account_attributes).find_or_create_by!(id: 1)

  sample_transactions_attributes.each do |transaction_id, transaction_attributes|
    Transaction.create_with(transaction_attributes).find_or_create_by!(id: transaction_id)
  end
end

# Explicit ids don't advance the sequences; without this the next insert would collide with id 1.
[BankAccount, Transaction].each do |model|
  model.connection_pool.with_connection { |connection| connection.reset_pk_sequence!(model.table_name) }
end
