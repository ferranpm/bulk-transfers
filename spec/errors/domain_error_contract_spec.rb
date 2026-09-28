# frozen_string_literal: true

RSpec.describe DomainError do
  {
    ValidationFailedError => ["validation_failed", 422],
    AccountNotFoundError => ["account_not_found", 422],
    InsufficientFundsError => ["insufficient_funds", 422],
    IdempotencyKeyReusedError => ["idempotency_key_reused", 422],
    MissingIdempotencyKeyError => ["missing_idempotency_key", 400],
    InvalidIdempotencyKeyError => ["invalid_idempotency_key", 400],
    InvalidJsonError => ["invalid_json", 400],
    ServiceUnavailableError => ["service_unavailable", 503]
  }.each do |error_class, (expected_code, expected_status_code)|
    context "with #{error_class}" do
      it "is a DomainError" do
        expect(error_class).to be < described_class
      end

      it "answers #{expected_code} with HTTP #{expected_status_code}" do
        error = error_class.new

        expect(error.code).to eq(expected_code)
        expect(Rack::Utils.status_code(error.http_status)).to eq(expected_status_code)
      end

      it "has a default message" do
        error = error_class.new

        expect(error.message).to be_present
        expect(error.message).not_to eq(error_class.name)
      end
    end
  end

  describe "#to_h" do
    it "renders the error envelope with the details" do
      error = InsufficientFundsError.new(details: { required_amount_cents: 200, available_balance_cents: 100 })

      envelope = error.to_h

      expect(envelope).to eq(
        error: {
          code: "insufficient_funds",
          message: "Insufficient funds",
          details: { required_amount_cents: 200, available_balance_cents: 100 }
        }
      )
    end

    it "renders null details when there are none" do
      error = AccountNotFoundError.new

      envelope = error.to_h

      expect(envelope.fetch(:error)).to include(code: "account_not_found", details: nil)
    end

    it "uses a custom message when one is given" do
      error = ValidationFailedError.new("Amount is not a string")

      envelope = error.to_h

      expect(envelope.dig(:error, :message)).to eq("Amount is not a string")
    end
  end
end
