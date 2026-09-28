# frozen_string_literal: true

# The only thing an operation returns: it never raises to its caller (PLAN operations-and-result).
#   Result.success(bulk_transfer, idempotent_replay: true) # => #<data Result ...>
#   Result.failure(InsufficientFundsError.new)             # => #<data Result ...>
Result = Data.define(:value, :errors, :idempotent_replay) do
  def self.success(value, idempotent_replay: false) = new(value:, errors: [].freeze, idempotent_replay:)

  def self.failure(error) = new(value: nil, errors: [error].freeze, idempotent_replay: false)

  def successful? = errors.empty?

  def failed? = !successful?

  def idempotent_replay? = idempotent_replay
end
