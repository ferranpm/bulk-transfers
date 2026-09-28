# frozen_string_literal: true

RSpec.describe TransactionGuard do
  describe ".ensure_transaction!" do
    it "passes inside a database transaction" do
      ActiveRecord::Base.transaction do
        expect { described_class.ensure_transaction! }.not_to raise_error
      end
    end

    context "without an open database transaction" do
      self.use_transactional_tests = false

      it "raises" do
        expect { described_class.ensure_transaction! }.to raise_error(TransactionRequiredError)
      end
    end
  end
end
