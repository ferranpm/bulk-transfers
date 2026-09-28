# frozen_string_literal: true

# A movement on an account: negative for a debit, positive for a credit
# (PLAN denormalized-balance-with-movement-log). Only Ledger writes these rows.
class Transaction < ApplicationRecord
  CURRENCY = "EUR"
  # SEPA field limits for the counterparty name and the remittance information.
  NAME_MAX_LENGTH = 70
  DESCRIPTION_MAX_LENGTH = 140

  belongs_to :bank_account
  belongs_to :bulk_transfer, optional: true

  validates :counterparty_name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :counterparty_iban, :counterparty_bic, presence: true
  validates :description, presence: true, length: { maximum: DESCRIPTION_MAX_LENGTH }
  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :amount_currency, inclusion: { in: [CURRENCY] }
end
