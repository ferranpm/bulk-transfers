# frozen_string_literal: true

RSpec.describe Ledger do
  describe ".debit!" do
    def credit_transfer(amount_cents:, counterparty_name: "Bip Bip")
      amount = format("%<euros>d.%<cents>02d", euros: amount_cents / 100, cents: amount_cents % 100)
      BulkTransfers::Request::CreditTransfer.new(
        amount:, amount_cents:, currency: "EUR", counterparty_name:,
        counterparty_iban: "EE383680981021245685", counterparty_bic: "CRLYFRPPTOU", description: "Wonderland/4410"
      )
    end

    context "with an open database transaction" do
      let(:bank_account) { create(:bank_account, opening_balance_cents: 10_000) }
      let(:credit_transfers) do
        [
          credit_transfer(amount_cents: 1_450, counterparty_name: "Bip Bip"),
          credit_transfer(amount_cents: 2_000, counterparty_name: "Wile E Coyote"),
          credit_transfer(amount_cents: 999, counterparty_name: "Bugs Bunny")
        ]
      end
      let(:bulk_transfer) { create(:bulk_transfer, bank_account:, transfer_count: 3, total_amount_cents: 4_449) }

      it "decrements the balance by the total of the bulk" do
        ActiveRecord::Base.transaction do
          described_class.debit!(account: bank_account, bulk_transfer:, credit_transfers:)
        end

        expect(bank_account.reload.balance_cents).to eq(5_551)
        expect_ledger_invariants!
      end

      it "writes one negative EUR transaction per credit transfer, in request order" do
        inserted_ids = ActiveRecord::Base.transaction do
          described_class.debit!(account: bank_account, bulk_transfer:, credit_transfers:)
        end

        debits = bulk_transfer.transactions.order(:id)
        expect(debits.map(&:id)).to eq(inserted_ids)
        expect(debits.map { |debit| [debit.counterparty_name, debit.amount_cents] }).to eq(
          [["Bip Bip", -1_450], ["Wile E Coyote", -2_000], ["Bugs Bunny", -999]]
        )
        expect(debits).to all(have_attributes(bank_account_id: bank_account.id, amount_currency: "EUR",
                                              counterparty_iban: "EE383680981021245685",
                                              counterparty_bic: "CRLYFRPPTOU", description: "Wonderland/4410"))
        expect_ledger_invariants!
      end

      it "debits the exact balance down to zero" do
        exact_bulk_transfer = create(:bulk_transfer, bank_account:, transfer_count: 1, total_amount_cents: 10_000)

        ActiveRecord::Base.transaction do
          described_class.debit!(account: bank_account, bulk_transfer: exact_bulk_transfer,
                                 credit_transfers: [credit_transfer(amount_cents: 10_000)])
        end

        expect(bank_account.reload.balance_cents).to eq(0)
        expect_ledger_invariants!
      end

      it "refuses a debit above the balance and writes nothing" do
        oversized_credit_transfers = [credit_transfer(amount_cents: 10_001)]
        bank_account

        expect do
          ActiveRecord::Base.transaction(requires_new: true) do
            oversized_bulk_transfer = create(:bulk_transfer, bank_account:, transfer_count: 1,
                                                             total_amount_cents: 10_001)
            described_class.debit!(account: bank_account, bulk_transfer: oversized_bulk_transfer,
                                   credit_transfers: oversized_credit_transfers)
          end
        end.to raise_error(InsufficientFundsError) { |error|
          expect(error.details).to eq(required_amount_cents: 10_001, available_balance_cents: 10_000)
        }.and(not_change { bank_account.reload.balance_cents })
         .and(not_change(Transaction, :count))
         .and(not_change(BulkTransfer, :count))
        expect_ledger_invariants!
      end
    end

    context "without an open database transaction" do
      self.use_transactional_tests = false

      it "raises before writing anything" do
        bank_account = build_stubbed(:bank_account, balance_cents: 10_000)
        bulk_transfer = build_stubbed(:bulk_transfer, bank_account:)

        credit_transfers = [credit_transfer(amount_cents: 100)]

        expect { described_class.debit!(account: bank_account, bulk_transfer:, credit_transfers:) }
          .to raise_error(TransactionRequiredError)
          .and not_change(Transaction, :count)
      end
    end
  end
end
