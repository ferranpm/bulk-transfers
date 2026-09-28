# frozen_string_literal: true

FactoryBot.define do
  factory :bank_account do
    transient do
      opening_balance_cents { 0 }
    end

    sequence(:organization_name) { |sequence_number| "Organization #{sequence_number}" }
    sequence(:iban) { |sequence_number| format("FR76%<number>023d", number: sequence_number) }
    bic { "OIVUSCLQXXX" }
    balance_cents { opening_balance_cents }

    # The opening balance is backed by a credit row so that the ledger invariant
    # balance_cents == SUM(transactions.amount_cents) holds from the first write
    # (PLAN denormalized-balance-with-movement-log).
    after(:create) do |bank_account, evaluator|
      if evaluator.opening_balance_cents.positive?
        create(:transaction, :credit, bank_account:, amount_cents: evaluator.opening_balance_cents)
      end
    end
  end
end
