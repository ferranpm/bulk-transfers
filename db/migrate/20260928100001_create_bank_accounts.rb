# frozen_string_literal: true

# Keeps the table and column names of the provided schema; the constraints make
# the database the last line of defence for money (PLAN schema-changes).
class CreateBankAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :bank_accounts do |table|
      table.string :organization_name, null: false
      table.bigint :balance_cents, null: false, default: 0
      table.string :iban, null: false
      table.string :bic, null: false
      table.timestamps

      table.check_constraint "balance_cents >= 0", name: "bank_accounts_balance_cents_non_negative"
      table.index %i[iban bic], unique: true
    end
  end
end
