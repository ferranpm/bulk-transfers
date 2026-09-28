# frozen_string_literal: true

# Turns a decimal euro string from the API into Integer cents without ever going through a Float
# (PLAN money-representation).
#   AmountParser.parse("14.5") # => #<data AmountParser::Outcome amount_cents=1450, issue=nil>
#   AmountParser.parse(14.5)   # => #<data AmountParser::Outcome amount_cents=nil, issue="must_be_a_string">
module AmountParser
  Outcome = Data.define(:amount_cents, :issue) do
    def valid? = issue.nil?
  end

  # BigDecimal alone would also accept "1e3", surrounding whitespace, "Infinity" and "NaN"; the whitelist
  # leaves only digits and dots, and "-" can't appear because debits are made negative internally.
  ALLOWED_CHARACTERS = /\A[0-9.]+\z/
  CENTS_PER_EURO = 100
  # Keeps every stored amount far inside bigint.
  MAX_AMOUNT_CENTS = 10**15

  module_function

  def parse(raw_amount)
    # A JSON number has already been through the client's float serializer, so the intended value is unknown.
    return invalid("must_be_a_string") unless raw_amount.is_a?(String)
    return invalid("invalid_format") unless ALLOWED_CHARACTERS.match?(raw_amount)

    euros = BigDecimal(raw_amount, exception: false)
    return invalid("invalid_format") if euros.nil?

    cents_from(euros * CENTS_PER_EURO)
  end

  def cents_from(cents)
    return invalid("must_be_positive") unless cents.positive?
    return invalid("too_many_decimals") unless cents.frac.zero?
    return invalid("too_large") if cents > MAX_AMOUNT_CENTS

    Outcome.new(amount_cents: cents.to_i, issue: nil)
  end

  def invalid(issue) = Outcome.new(amount_cents: nil, issue:)
end
