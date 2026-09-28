# frozen_string_literal: true

# An accepted bulk and the idempotency key it was submitted with
# (PLAN idempotency-key-and-fingerprint). Failed requests are never persisted.
class BulkTransfer < ApplicationRecord
  IDEMPOTENCY_KEY_MAX_LENGTH = 255

  belongs_to :bank_account
  has_many :transactions, dependent: :restrict_with_exception

  validates :idempotency_key, presence: true, length: { maximum: IDEMPOTENCY_KEY_MAX_LENGTH }
  validates :request_fingerprint, presence: true
  validates :transfer_count, numericality: { only_integer: true, greater_than: 0 }
  validates :total_amount_cents, numericality: { only_integer: true, greater_than: 0 }
end
