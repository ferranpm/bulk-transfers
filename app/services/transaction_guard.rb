# frozen_string_literal: true

# Inner services that write money call this instead of opening their own transaction: the operation owns the
# boundary, and writing outside one could commit a half-applied bulk (PLAN operations-and-result).
#   TransactionGuard.ensure_transaction! # => nil, or raises TransactionRequiredError
module TransactionGuard
  module_function

  def ensure_transaction!
    transaction_open = ActiveRecord::Base.with_connection(&:transaction_open?)
    raise TransactionRequiredError unless transaction_open
  end
end
