# frozen_string_literal: true

# Balance is only ever written by Ledger (PLAN operations-and-result).
class BankAccount < ApplicationRecord
  has_many :transactions, dependent: :restrict_with_exception
  has_many :bulk_transfers, dependent: :restrict_with_exception

  validates :organization_name, :iban, :bic, presence: true
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
