# frozen_string_literal: true

# Append-only movements log: debits negative, credits positive, never zero
# (PLAN denormalized-balance-with-movement-log, schema-changes).
class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |table|
      table.string :counterparty_name, null: false
      table.string :counterparty_iban, null: false
      table.string :counterparty_bic, null: false
      table.bigint :amount_cents, null: false
      table.string :amount_currency, null: false
      table.references :bank_account, null: false, foreign_key: true
      table.string :description, null: false
      # Nullable: the seeded transactions were not created by a bulk.
      table.references :bulk_transfer, null: true, foreign_key: true
      table.timestamps

      table.check_constraint "amount_cents <> 0", name: "transactions_amount_cents_non_zero"
      table.check_constraint "amount_currency = 'EUR'", name: "transactions_amount_currency_eur"
      table.check_constraint "char_length(counterparty_name) <= 70", name: "transactions_counterparty_name_length"
      table.check_constraint "char_length(description) <= 140", name: "transactions_description_length"
    end
  end
end
