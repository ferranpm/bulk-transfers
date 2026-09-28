# frozen_string_literal: true

# Base of every error the API can answer with. Each subclass declares its contract in one line, so the
# error code and the HTTP status live side by side (PLAN error-model).
#   raise InsufficientFundsError.new(details: { required_amount_cents:, available_balance_cents: })
#   error.to_h # => { error: { code: "insufficient_funds", message: "Insufficient funds", details: {...} } }
class DomainError < StandardError
  class << self
    attr_reader :code, :http_status, :default_message

    def configure(code:, http_status:, default_message:)
      @code = code
      @http_status = http_status
      @default_message = default_message
    end
  end

  attr_reader :details

  def initialize(message = nil, details: nil)
    super(message || self.class.default_message)
    @details = details
  end

  delegate :code, to: :class

  delegate :http_status, to: :class

  def to_h = { error: { code:, message:, details: } }
end
