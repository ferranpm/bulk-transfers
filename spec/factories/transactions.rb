# frozen_string_literal: true

FactoryBot.define do
  factory :transaction do
    bank_account
    counterparty_name { "Bip Bip" }
    counterparty_iban { "EE383680981021245685" }
    counterparty_bic { "CRLYFRPPTOU" }
    amount_cents { -1_000 }
    amount_currency { Transaction::CURRENCY }
    description { "Wonderland/4410" }

    trait :credit do
      counterparty_name { "ACME Corp. Main Account" }
      counterparty_iban { "EE382200221020145685" }
      counterparty_bic { "CCOPFRPPXXX" }
      amount_cents { 1_000 }
      description { "Treasury income" }
    end
  end
end
