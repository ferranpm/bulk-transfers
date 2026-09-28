# frozen_string_literal: true

# A programming error, deliberately not a DomainError: operations turn DomainErrors into failure Results, and this
# must surface as a bug (a 500), never as a client-facing answer (PLAN operations-and-result).
class TransactionRequiredError < StandardError
  def initialize(message = "Money can only move inside a database transaction opened by an operation")
    super
  end
end
