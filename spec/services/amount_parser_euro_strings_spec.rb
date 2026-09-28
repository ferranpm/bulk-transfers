# frozen_string_literal: true

RSpec.describe AmountParser do
  describe ".parse" do
    {
      "14.5" => 1_450,
      "61238" => 6_123_800,
      "8024.99" => 802_499,
      "1.500" => 150,
      ".5" => 50,
      "1." => 100,
      "0.01" => 1,
      "10000000000000" => AmountParser::MAX_AMOUNT_CENTS
    }.each do |raw_amount, expected_amount_cents|
      it "reads #{raw_amount.inspect} as #{expected_amount_cents} cents" do
        outcome = described_class.parse(raw_amount)

        expect(outcome).to be_valid
        expect(outcome.amount_cents).to eq(expected_amount_cents)
        expect(outcome.amount_cents).to be_an(Integer)
      end
    end

    {
      "0" => "must_be_positive",
      "0.00" => "must_be_positive",
      "-1" => "invalid_format",
      "1.234" => "too_many_decimals",
      "1e3" => "invalid_format",
      " 12" => "invalid_format",
      "12 " => "invalid_format",
      "NaN" => "invalid_format",
      "Infinity" => "invalid_format",
      "1,50" => "invalid_format",
      "1.2.3" => "invalid_format",
      "." => "invalid_format",
      "" => "invalid_format",
      "10000000000000.01" => "too_large",
      12 => "must_be_a_string",
      12.5 => "must_be_a_string",
      nil => "must_be_a_string",
      { "value" => "12" } => "must_be_a_string"
    }.each do |raw_amount, expected_issue|
      it "rejects #{raw_amount.inspect} as #{expected_issue}" do
        outcome = described_class.parse(raw_amount)

        expect(outcome).not_to be_valid
        expect(outcome.issue).to eq(expected_issue)
        expect(outcome.amount_cents).to be_nil
      end
    end
  end
end
