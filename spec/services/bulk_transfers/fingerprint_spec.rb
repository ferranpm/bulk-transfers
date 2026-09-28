# frozen_string_literal: true

RSpec.describe BulkTransfers::Fingerprint do
  let(:first_credit_transfer) do
    {
      "amount" => "14.5",
      "currency" => "EUR",
      "counterparty_name" => "Bip Bip",
      "counterparty_bic" => "CRLYFRPPTOU",
      "counterparty_iban" => "EE383680981021245685",
      "description" => "Wonderland/4410"
    }
  end
  let(:second_credit_transfer) do
    first_credit_transfer.merge("amount" => "61238", "counterparty_name" => "Wile E Coyote")
  end
  let(:request_fields) do
    {
      organization_iban: "FR10474608000002006107XXXXX",
      organization_bic: "OIVUSCLQXXX",
      credit_transfers: [first_credit_transfer, second_credit_transfer]
    }
  end

  def fingerprint_of(fields) = described_class.call(BulkTransfers::Request.parse(**fields))

  it "is a SHA-256 hex digest" do
    fingerprint = fingerprint_of(request_fields)

    expect(fingerprint).to match(/\A\h{64}\z/)
  end

  it "is stable for the same request" do
    fingerprint = fingerprint_of(request_fields)

    expect(fingerprint_of(request_fields)).to eq(fingerprint)
  end

  it "ignores the order of keys" do
    reordered_credit_transfers = [first_credit_transfer.to_a.reverse.to_h, second_credit_transfer.to_a.reverse.to_h]

    fingerprint = fingerprint_of(request_fields.merge(credit_transfers: reordered_credit_transfers))

    expect(fingerprint).to eq(fingerprint_of(request_fields))
  end

  it "ignores unknown fields" do
    credit_transfers_with_extras = [first_credit_transfer.merge("reference" => "x"), second_credit_transfer]

    fingerprint = fingerprint_of(request_fields.merge(credit_transfers: credit_transfers_with_extras))

    expect(fingerprint).to eq(fingerprint_of(request_fields))
  end

  it "changes with the order of the credit transfers" do
    reversed_credit_transfers = [second_credit_transfer, first_credit_transfer]

    fingerprint = fingerprint_of(request_fields.merge(credit_transfers: reversed_credit_transfers))

    expect(fingerprint).not_to eq(fingerprint_of(request_fields))
  end

  it "changes with the amount string even when the value in cents is the same" do
    credit_transfers = [first_credit_transfer.merge("amount" => "14.50"), second_credit_transfer]

    fingerprint = fingerprint_of(request_fields.merge(credit_transfers:))

    expect(fingerprint).not_to eq(fingerprint_of(request_fields))
  end

  {
    "counterparty_name" => "Road Runner",
    "counterparty_bic" => "ZDRPLBQI",
    "counterparty_iban" => "NL24ABNA5055036109",
    "description" => "Wonderland/4411"
  }.each do |field, other_value|
    it "changes with the #{field} of a credit transfer" do
      credit_transfers = [first_credit_transfer, second_credit_transfer.merge(field => other_value)]

      fingerprint = fingerprint_of(request_fields.merge(credit_transfers:))

      expect(fingerprint).not_to eq(fingerprint_of(request_fields))
    end
  end

  it "changes with the organization account" do
    fingerprint = fingerprint_of(request_fields.merge(organization_bic: "OIVUSCLQ"))

    expect(fingerprint).not_to eq(fingerprint_of(request_fields))
  end
end
