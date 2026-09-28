# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_28_100003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bank_accounts", force: :cascade do |t|
    t.string "organization_name", null: false
    t.bigint "balance_cents", default: 0, null: false
    t.string "iban", null: false
    t.string "bic", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["iban", "bic"], name: "index_bank_accounts_on_iban_and_bic", unique: true
    t.check_constraint "balance_cents >= 0", name: "bank_accounts_balance_cents_non_negative"
  end

  create_table "bulk_transfers", force: :cascade do |t|
    t.bigint "bank_account_id", null: false
    t.string "idempotency_key", null: false
    t.string "request_fingerprint", null: false
    t.integer "transfer_count", null: false
    t.bigint "total_amount_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_account_id", "idempotency_key"], name: "index_bulk_transfers_on_bank_account_id_and_idempotency_key", unique: true
  end

  create_table "transactions", force: :cascade do |t|
    t.string "counterparty_name", null: false
    t.string "counterparty_iban", null: false
    t.string "counterparty_bic", null: false
    t.bigint "amount_cents", null: false
    t.string "amount_currency", null: false
    t.bigint "bank_account_id", null: false
    t.string "description", null: false
    t.bigint "bulk_transfer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_account_id"], name: "index_transactions_on_bank_account_id"
    t.index ["bulk_transfer_id"], name: "index_transactions_on_bulk_transfer_id"
    t.check_constraint "amount_cents <> 0", name: "transactions_amount_cents_non_zero"
    t.check_constraint "amount_currency::text = 'EUR'::text", name: "transactions_amount_currency_eur"
    t.check_constraint "char_length(counterparty_name::text) <= 70", name: "transactions_counterparty_name_length"
    t.check_constraint "char_length(description::text) <= 140", name: "transactions_description_length"
  end

  add_foreign_key "bulk_transfers", "bank_accounts"
  add_foreign_key "transactions", "bank_accounts"
  add_foreign_key "transactions", "bulk_transfers"
end
