# frozen_string_literal: true

RSpec.describe "db:seed", type: :task do
  subject(:seed) { Rails.application.load_seed }

  it "creates the ACME Corp account from the sample database" do
    seed

    expect(BankAccount.find(1)).to have_attributes(
      organization_name: "ACME Corp",
      balance_cents: 10_000_000,
      iban: "FR10474608000002006107XXXXX",
      bic: "OIVUSCLQXXX"
    )
  end

  it "creates the two sample transactions with their original ids" do
    seed

    seeded_transactions = Transaction.order(:id).map do |transaction|
      transaction.attributes.symbolize_keys.except(:created_at, :updated_at)
    end

    expect(seeded_transactions).to eq(
      [
        { id: 1,
          counterparty_name: "ACME Corp. Main Account",
          counterparty_iban: "EE382200221020145685",
          counterparty_bic: "CCOPFRPPXXX",
          amount_cents: 11_000_000,
          amount_currency: "EUR",
          bank_account_id: 1,
          description: "Treasury income",
          bulk_transfer_id: nil },
        { id: 2,
          counterparty_name: "Bip Bip",
          counterparty_iban: "EE383680981021245685",
          counterparty_bic: "CRLYFRPPTOU",
          amount_cents: -1_000_000,
          amount_currency: "EUR",
          bank_account_id: 1,
          description: "Bip Bip Salary",
          bulk_transfer_id: nil }
      ]
    )
  end

  it "seeds a balance that equals the sum of the account's transactions" do
    seed

    expect_ledger_invariants!
  end

  it "hands out the next ids after the seeded ones" do
    seed

    expect(create(:bank_account).id).to eq(2)
    expect(create(:transaction, bank_account_id: 1).id).to eq(3)
  end

  context "when the account has moved money since it was first seeded" do
    before do
      Rails.application.load_seed
      create(:transaction, bank_account_id: 1, amount_cents: -2_500)
      BankAccount.find(1).update!(balance_cents: 9_997_500)
    end

    it "leaves the live balance and the transactions untouched" do
      expect { seed }
        .to not_change { BankAccount.find(1).balance_cents }.from(9_997_500)
        .and not_change(BankAccount, :count)
        .and not_change(Transaction, :count)
      expect_ledger_invariants!
    end
  end
end
