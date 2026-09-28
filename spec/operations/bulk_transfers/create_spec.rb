# frozen_string_literal: true

RSpec.describe BulkTransfers::Create do
  describe ".call" do
    def credit_transfer_params(amount:, counterparty_name: "Bip Bip")
      {
        "amount" => amount, "currency" => "EUR", "counterparty_name" => counterparty_name,
        "counterparty_iban" => "EE383680981021245685", "counterparty_bic" => "CRLYFRPPTOU",
        "description" => "Wonderland/4410"
      }
    end

    def call_operation(credit_transfers: default_credit_transfers, idempotency_key: "key-1", account: bank_account)
      described_class.call(
        organization_iban: account.iban, organization_bic: account.bic, credit_transfers:, idempotency_key:
      )
    end

    let(:bank_account) { create(:bank_account, opening_balance_cents: 10_000) }
    let(:default_credit_transfers) do
      [
        credit_transfer_params(amount: "14.5", counterparty_name: "Bip Bip"),
        credit_transfer_params(amount: "20", counterparty_name: "Wile E Coyote")
      ]
    end

    context "when the account can cover the bulk" do
      it "returns a successful, frozen result holding the new bulk transfer" do
        result = call_operation

        expect(result).to be_successful.and be_frozen
        expect(result).not_to be_idempotent_replay
        expect(result.value).to have_attributes(
          bank_account_id: bank_account.id, idempotency_key: "key-1", transfer_count: 2, total_amount_cents: 3_450
        )
        expect_ledger_invariants!
      end

      it "debits the balance and writes one transaction per credit transfer, in request order" do
        result = call_operation

        expect(bank_account.reload.balance_cents).to eq(6_550)
        expect(result.value.transactions.order(:id).pluck(:counterparty_name, :amount_cents))
          .to eq([["Bip Bip", -1_450], ["Wile E Coyote", -2_000]])
        expect_ledger_invariants!
      end

      it "debits the exact balance down to zero" do
        result = call_operation(credit_transfers: [credit_transfer_params(amount: "100.00")])

        expect(result).to be_successful
        expect(bank_account.reload.balance_cents).to eq(0)
        expect_ledger_invariants!
      end
    end

    context "when the same key is sent again with the same body" do
      it "replays the original bulk transfer without moving money again" do
        original = call_operation

        replay = nil
        expect { replay = call_operation }.not_to(change { ledger_snapshot })

        expect(replay).to be_successful.and be_idempotent_replay
        expect(replay.value).to eq(original.value)
        expect_ledger_invariants!
      end
    end

    context "when the same key is sent again with a different body" do
      it "fails with idempotency_key_reused and changes nothing" do
        call_operation
        different_credit_transfers = [credit_transfer_params(amount: "1")]

        result = nil
        expect { result = call_operation(credit_transfers: different_credit_transfers) }
          .not_to(change { ledger_snapshot })

        expect(result).to be_failed.and be_frozen
        expect(result.errors.sole).to be_a(IdempotencyKeyReusedError)
        expect_ledger_invariants!
      end
    end

    context "when the same key is used by another account" do
      it "treats it as a new request for that account" do
        call_operation
        other_account = create(:bank_account, opening_balance_cents: 10_000)

        result = call_operation(account: other_account)

        expect(result).to be_successful
        expect(result).not_to be_idempotent_replay
        expect(other_account.reload.balance_cents).to eq(6_550)
        expect_ledger_invariants!
      end
    end

    context "when no account matches the IBAN and BIC" do
      it "fails with account_not_found and changes nothing" do
        bank_account

        result = nil
        expect do
          result = described_class.call(
            organization_iban: bank_account.iban, organization_bic: "CRLYFRPPTOU",
            credit_transfers: default_credit_transfers, idempotency_key: "key-1"
          )
        end.not_to(change { ledger_snapshot })

        expect(result).to be_failed
        expect(result.errors.sole).to be_a(AccountNotFoundError)
        expect_ledger_invariants!
      end
    end

    context "when the bulk exceeds the balance" do
      it "fails with insufficient_funds, reports the amounts and changes nothing" do
        oversized_credit_transfers = [credit_transfer_params(amount: "60"), credit_transfer_params(amount: "40.01")]
        bank_account

        result = nil
        expect { result = call_operation(credit_transfers: oversized_credit_transfers) }
          .not_to(change { ledger_snapshot })

        expect(result).to be_failed
        expect(result.errors.sole).to be_a(InsufficientFundsError)
        expect(result.errors.sole.details).to eq(required_amount_cents: 10_001, available_balance_cents: 10_000)
        expect_ledger_invariants!
      end
    end

    context "when the request is invalid" do
      it "fails with validation_failed and changes nothing" do
        bank_account

        result = nil
        expect { result = call_operation(credit_transfers: [credit_transfer_params(amount: "0")]) }
          .not_to(change { ledger_snapshot })

        expect(result).to be_failed
        expect(result.errors.sole).to be_a(ValidationFailedError)
        expect(result.errors.sole.details).to eq([{ index: 0, field: "amount", issue: "must_be_positive" }])
        expect_ledger_invariants!
      end
    end

    context "when another connection holds the account lock past the lock timeout", :concurrency do
      it "fails with service_unavailable and changes nothing" do
        bank_account

        result = nil
        expect do
          while_account_locked_elsewhere(bank_account) do
            result = with_lock_timeout("50ms") { call_operation }
          end
        end.not_to(change { ledger_snapshot })

        expect(result).to be_failed.and be_frozen
        expect(result.errors.sole).to be_a(ServiceUnavailableError)
        expect_ledger_invariants!
      end
    end
  end
end
