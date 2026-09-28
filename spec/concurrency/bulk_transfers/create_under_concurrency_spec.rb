# frozen_string_literal: true

RSpec.describe BulkTransfers::Create, :concurrency do
  describe ".call" do
    def credit_transfer_params(amount:)
      {
        "amount" => amount, "currency" => "EUR", "counterparty_name" => "Bip Bip",
        "counterparty_iban" => "EE383680981021245685", "counterparty_bic" => "CRLYFRPPTOU",
        "description" => "Wonderland/4410"
      }
    end

    def call_operation(account:, idempotency_key:, amount: "60")
      described_class.call(
        organization_iban: account.iban, organization_bic: account.bic,
        credit_transfers: [credit_transfer_params(amount:)], idempotency_key:
      )
    end

    def error_codes(results) = results.select(&:failed?).map { it.errors.sole.code }

    let(:parallel_request_count) { 8 }
    let(:bank_account) { create(:bank_account, opening_balance_cents: 10_000) }

    context "with two bulks that each fit the balance alone but not together" do
      it "accepts exactly one and refuses the other for insufficient funds" do
        bank_account

        results = run_in_parallel(2) { |index| call_operation(account: bank_account, idempotency_key: "key-#{index}") }

        expect(results.count(&:successful?)).to eq(1)
        expect(error_codes(results)).to eq(["insufficient_funds"])
        expect(bank_account.reload.balance_cents).to eq(4_000)
        expect(BulkTransfer.count).to eq(1)
        expect_ledger_invariants!
      end
    end

    context "with parallel requests sharing a key and a body" do
      it "applies the bulk once and replays it for every other request" do
        bank_account

        results = run_in_parallel(parallel_request_count) do
          call_operation(account: bank_account, idempotency_key: "shared-key")
        end

        expect(results).to all(be_successful)
        expect(results.count(&:idempotent_replay?)).to eq(parallel_request_count - 1)
        expect(results.map(&:value).uniq).to contain_exactly(BulkTransfer.sole)
        expect(Transaction.where.not(bulk_transfer_id: nil).count).to eq(1)
        expect(bank_account.reload.balance_cents).to eq(4_000)
        expect_ledger_invariants!
      end
    end

    context "with parallel requests sharing a key but not a body" do
      it "applies one bulk and refuses every other request as a reused key" do
        bank_account

        results = run_in_parallel(parallel_request_count) do |index|
          call_operation(account: bank_account, idempotency_key: "shared-key", amount: (index + 1).to_s)
        end

        winning_result = results.find(&:successful?)
        expect(results.count(&:successful?)).to eq(1)
        expect(winning_result).not_to be_idempotent_replay
        expect(error_codes(results)).to eq(["idempotency_key_reused"] * (parallel_request_count - 1))
        expect(bank_account.reload.balance_cents).to eq(10_000 - winning_result.value.total_amount_cents)
        expect(BulkTransfer.count).to eq(1)
        expect_ledger_invariants!
      end
    end

    context "with bulks on different accounts" do
      it "applies them all in parallel" do
        accounts = create_list(:bank_account, parallel_request_count, opening_balance_cents: 10_000)

        results = run_in_parallel(parallel_request_count) do |index|
          call_operation(account: accounts[index], idempotency_key: "shared-key")
        end

        expect(results).to all(be_successful)
        expect(results).to all(satisfy { !it.idempotent_replay? })
        expect(accounts.map { it.reload.balance_cents }).to all(eq(4_000))
        expect_ledger_invariants!
      end

      it "is not blocked by a lock held on another account" do
        locked_account = bank_account
        free_account = create(:bank_account, opening_balance_cents: 10_000)

        result = while_account_locked_elsewhere(locked_account) do
          with_lock_timeout("200ms") { call_operation(account: free_account, idempotency_key: "key-1") }
        end

        expect(result).to be_successful
        expect(free_account.reload.balance_cents).to eq(4_000)
        expect(locked_account.reload.balance_cents).to eq(10_000)
        expect_ledger_invariants!
      end
    end
  end
end
