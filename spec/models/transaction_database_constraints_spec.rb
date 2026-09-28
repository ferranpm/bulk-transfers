# frozen_string_literal: true

RSpec.describe Transaction do
  describe "database constraints" do
    it "rejects a zero amount even when validations are skipped" do
      transaction = build(:transaction, amount_cents: 0)

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::CheckViolation, /amount_cents/)
        .and not_change(described_class, :count)
    end

    it "rejects a currency other than EUR even when validations are skipped" do
      transaction = build(:transaction, amount_currency: "USD")

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::CheckViolation, /amount_currency/)
        .and not_change(described_class, :count)
    end

    it "rejects a counterparty name longer than 70 characters even when validations are skipped" do
      transaction = build(:transaction, counterparty_name: "a" * (Transaction::NAME_MAX_LENGTH + 1))

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::CheckViolation, /counterparty_name/)
        .and not_change(described_class, :count)
    end

    it "accepts a counterparty name of exactly 70 multibyte characters" do
      transaction = build(:transaction, counterparty_name: "é" * Transaction::NAME_MAX_LENGTH)

      expect { transaction.save(validate: false) }.to change(described_class, :count).by(1)
    end

    it "rejects a description longer than 140 characters even when validations are skipped" do
      transaction = build(:transaction, description: "a" * (Transaction::DESCRIPTION_MAX_LENGTH + 1))

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::CheckViolation, /description/)
        .and not_change(described_class, :count)
    end

    it "rejects an unknown bank account even when validations are skipped" do
      transaction = build(:transaction, bank_account_id: 0)

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
        .and not_change(described_class, :count)
    end

    it "rejects an unknown bulk transfer even when validations are skipped" do
      transaction = build(:transaction, bulk_transfer_id: 0)

      expect { transaction.save(validate: false) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
        .and not_change(described_class, :count)
    end

    it "accepts a transaction that belongs to no bulk, like the seeded ones" do
      transaction = build(:transaction, bulk_transfer: nil)

      expect { transaction.save(validate: false) }.to change(described_class, :count).by(1)
    end

    %i[
      counterparty_name counterparty_iban counterparty_bic amount_cents amount_currency description
    ].each do |required_column|
      it "rejects a null #{required_column} even when validations are skipped" do
        transaction = build(:transaction, required_column => nil)

        expect { transaction.save(validate: false) }
          .to raise_error(ActiveRecord::NotNullViolation)
          .and not_change(described_class, :count)
      end
    end
  end
end
