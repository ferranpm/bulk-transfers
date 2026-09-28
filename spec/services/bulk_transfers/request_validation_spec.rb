# frozen_string_literal: true

RSpec.describe BulkTransfers::Request do
  let(:valid_credit_transfer) do
    {
      "amount" => "14.5",
      "currency" => "EUR",
      "counterparty_name" => "Bip Bip",
      "counterparty_bic" => "CRLYFRPPTOU",
      "counterparty_iban" => "EE383680981021245685",
      "description" => "Wonderland/4410"
    }
  end
  let(:valid_fields) do
    {
      organization_iban: "FR10474608000002006107XXXXX",
      organization_bic: "OIVUSCLQXXX",
      credit_transfers: [valid_credit_transfer, valid_credit_transfer.merge("amount" => "61238")]
    }
  end

  def expect_validation_details(fields, expected_details)
    expect { described_class.parse(**fields) }.to raise_error(ValidationFailedError) { |error|
      expect(error.details).to eq(expected_details)
    }
  end

  describe "a valid request" do
    it "exposes the organization and every credit transfer in Integer cents" do
      request = described_class.parse(**valid_fields)

      expect(request).to have_attributes(
        organization_iban: "FR10474608000002006107XXXXX",
        organization_bic: "OIVUSCLQXXX",
        transfer_count: 2,
        total_amount_cents: 6_125_250
      )
      expect(request.credit_transfers.first).to have_attributes(
        amount: "14.5", amount_cents: 1_450, currency: "EUR", counterparty_name: "Bip Bip",
        counterparty_bic: "CRLYFRPPTOU", counterparty_iban: "EE383680981021245685", description: "Wonderland/4410"
      )
    end

    it "is immutable" do
      request = described_class.parse(**valid_fields)

      expect(request).to be_frozen
      expect(request.credit_transfers).to be_frozen
      expect(request.credit_transfers).to all(be_frozen)
    end

    it "ignores unknown credit transfer fields" do
      fields = valid_fields.merge(credit_transfers: [valid_credit_transfer.merge("reference" => "extra")])

      request = described_class.parse(**fields)

      expect(request.credit_transfers.first).not_to respond_to(:reference)
      expect(request.fingerprint_params.dig("credit_transfers", 0)).not_to have_key("reference")
    end

    it "keeps the whitelisted params with amounts exactly as sent for the fingerprint" do
      fields = valid_fields.merge(credit_transfers: [valid_credit_transfer.merge("amount" => "1.500")])

      request = described_class.parse(**fields)

      expect(request.fingerprint_params).to eq(
        "organization_iban" => "FR10474608000002006107XXXXX",
        "organization_bic" => "OIVUSCLQXXX",
        "credit_transfers" => [valid_credit_transfer.merge("amount" => "1.500")]
      )
    end
  end

  describe "organization fields" do
    {
      nil => "missing",
      42 => "must_be_a_string",
      "" => "blank",
      "fr10474608000002006107xxxxx" => "invalid_format",
      "FR1047460800000200610700000000000000" => "invalid_format"
    }.each do |organization_iban, expected_issue|
      it "reports organization_iban #{organization_iban.inspect} as #{expected_issue}" do
        fields = valid_fields.merge(organization_iban:)

        expect_validation_details(fields, [{ field: "organization_iban", issue: expected_issue }])
      end
    end

    { nil => "missing", "OIVUSCL" => "invalid_format", "OIVUSCLQXX" => "invalid_format" }.each do |bic, expected_issue|
      it "reports organization_bic #{bic.inspect} as #{expected_issue}" do
        fields = valid_fields.merge(organization_bic: bic)

        expect_validation_details(fields, [{ field: "organization_bic", issue: expected_issue }])
      end
    end
  end

  describe "the credit_transfers list" do
    { nil => "missing", "abc" => "must_be_an_array", { "amount" => "1" } => "must_be_an_array",
      [] => "must_not_be_empty" }.each do |credit_transfers, expected_issue|
      it "reports #{credit_transfers.inspect} as #{expected_issue}" do
        fields = valid_fields.merge(credit_transfers:)

        expect_validation_details(fields, [{ field: "credit_transfers", issue: expected_issue }])
      end
    end

    it "reports an item that is not an object at its index" do
      fields = valid_fields.merge(credit_transfers: [valid_credit_transfer, "not an object"])

      expect_validation_details(fields, [{ index: 1, field: "credit_transfers", issue: "must_be_an_object" }])
    end

    it "accepts a large bulk, since there is no cap on its size" do
      fields = valid_fields.merge(credit_transfers: Array.new(2_000, valid_credit_transfer))

      request = described_class.parse(**fields)

      expect(request.transfer_count).to eq(2_000)
    end
  end

  describe "credit transfer fields" do
    {
      "amount" => { nil => "missing", 14.5 => "must_be_a_string", "1.234" => "too_many_decimals",
                    "0" => "must_be_positive", "1e3" => "invalid_format" },
      "currency" => { nil => "missing", "USD" => "unsupported_currency", "eur" => "unsupported_currency" },
      "counterparty_name" => { nil => "missing", " " => "blank", "a" * 71 => "too_long" },
      "counterparty_iban" => { "EE38 3680 9810 2124 5685" => "invalid_format", 123 => "must_be_a_string" },
      "counterparty_bic" => { "CRLYFRPP-TOU" => "invalid_format" },
      "description" => { nil => "missing", "a" * 141 => "too_long" }
    }.each do |field, issues_by_value|
      issues_by_value.each do |value, expected_issue|
        it "reports #{field} #{value.inspect.truncate(20)} as #{expected_issue}" do
          invalid_credit_transfer = valid_credit_transfer.merge(field => value)
          fields = valid_fields.merge(credit_transfers: [valid_credit_transfer, invalid_credit_transfer])

          expect_validation_details(fields, [{ index: 1, field:, issue: expected_issue }])
        end
      end
    end

    it "accepts a name of 70 and a description of 140 characters" do
      credit_transfer = valid_credit_transfer.merge("counterparty_name" => "a" * 70, "description" => "d" * 140)

      request = described_class.parse(**valid_fields, credit_transfers: [credit_transfer])

      expect(request.transfer_count).to eq(1)
    end

    it "accepts an 8-character BIC and the sample IBANs" do
      credit_transfer = valid_credit_transfer.merge("counterparty_bic" => "ZDRPLBQI",
                                                    "counterparty_iban" => "NL24ABNA5055036109")

      request = described_class.parse(**valid_fields, credit_transfers: [credit_transfer])

      expect(request.credit_transfers.first.counterparty_bic).to eq("ZDRPLBQI")
    end
  end

  it "collects every error across the organization and several items at once" do
    fields = {
      organization_iban: nil,
      organization_bic: "OIVUSCLQXXX",
      credit_transfers: [
        valid_credit_transfer.merge("amount" => 12, "currency" => "USD"),
        valid_credit_transfer,
        valid_credit_transfer.merge("description" => nil)
      ]
    }

    expect_validation_details(
      fields,
      [
        { field: "organization_iban", issue: "missing" },
        { index: 0, field: "amount", issue: "must_be_a_string" },
        { index: 0, field: "currency", issue: "unsupported_currency" },
        { index: 2, field: "description", issue: "missing" }
      ]
    )
  end

  it "reports every required field as missing when the body is not an object" do
    fields = { organization_iban: nil, organization_bic: nil, credit_transfers: nil }

    expect_validation_details(
      fields,
      [
        { field: "organization_iban", issue: "missing" },
        { field: "organization_bic", issue: "missing" },
        { field: "credit_transfers", issue: "missing" }
      ]
    )
  end
end
