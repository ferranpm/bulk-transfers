# frozen_string_literal: true

# One row per accepted bulk. The unique key per account is what makes a retry a
# replay instead of a second debit (PLAN idempotency-key-and-fingerprint).
class CreateBulkTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_transfers do |table|
      table.references :bank_account, null: false, foreign_key: true, index: false
      table.string :idempotency_key, null: false
      table.string :request_fingerprint, null: false
      table.integer :transfer_count, null: false
      table.bigint :total_amount_cents, null: false
      table.timestamps

      table.index %i[bank_account_id idempotency_key], unique: true
    end
  end
end
