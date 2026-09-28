# frozen_string_literal: true

FactoryBot.define do
  factory :bulk_transfer do
    bank_account
    sequence(:idempotency_key) { |sequence_number| "idempotency-key-#{sequence_number}" }
    request_fingerprint { Digest::SHA256.hexdigest("request") }
    transfer_count { 1 }
    total_amount_cents { 1_000 }
  end
end
