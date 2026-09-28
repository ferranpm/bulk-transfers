# frozen_string_literal: true

RSpec.describe BulkTransfer do
  describe "database constraints" do
    it "rejects a reused idempotency key on the same account even when validations are skipped" do
      existing_bulk = create(:bulk_transfer)
      duplicate_bulk = build(:bulk_transfer,
                             bank_account: existing_bulk.bank_account,
                             idempotency_key: existing_bulk.idempotency_key)

      expect { duplicate_bulk.save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
        .and not_change(described_class, :count)
    end

    it "accepts the same idempotency key on another account" do
      existing_bulk = create(:bulk_transfer)
      other_account_bulk = build(:bulk_transfer, idempotency_key: existing_bulk.idempotency_key)

      expect { other_account_bulk.save(validate: false) }.to change(described_class, :count).by(1)
    end

    it "rejects an unknown bank account even when validations are skipped" do
      bulk_transfer = build(:bulk_transfer, bank_account_id: 0)

      expect { bulk_transfer.save(validate: false) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
        .and not_change(described_class, :count)
    end

    %i[bank_account_id idempotency_key request_fingerprint transfer_count total_amount_cents].each do |required_column|
      it "rejects a null #{required_column} even when validations are skipped" do
        bulk_transfer = build(:bulk_transfer, required_column => nil)

        expect { bulk_transfer.save(validate: false) }
          .to raise_error(ActiveRecord::NotNullViolation)
          .and not_change(described_class, :count)
      end
    end
  end
end
