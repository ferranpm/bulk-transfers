# frozen_string_literal: true

RSpec.describe BankAccount do
  describe "database constraints" do
    it "rejects a negative balance even when validations are skipped" do
      bank_account = create(:bank_account)
      bank_account.balance_cents = -1

      expect { bank_account.save(validate: false) }.to raise_error(ActiveRecord::CheckViolation, /balance_cents/)
      expect(bank_account.reload.balance_cents).to eq(0)
    end

    it "rejects a second account with the same IBAN and BIC" do
      existing_account = create(:bank_account)
      duplicate_account = build(:bank_account, iban: existing_account.iban, bic: existing_account.bic)

      expect { duplicate_account.save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
        .and not_change(described_class, :count)
    end

    it "accepts the same IBAN under a different BIC" do
      existing_account = create(:bank_account)
      other_account = build(:bank_account, iban: existing_account.iban, bic: "CRLYFRPPTOU")

      expect { other_account.save(validate: false) }.to change(described_class, :count).by(1)
    end

    %i[organization_name iban bic balance_cents].each do |required_column|
      it "rejects a null #{required_column} even when validations are skipped" do
        bank_account = build(:bank_account, required_column => nil)

        expect { bank_account.save(validate: false) }
          .to raise_error(ActiveRecord::NotNullViolation)
          .and not_change(described_class, :count)
      end
    end
  end
end
