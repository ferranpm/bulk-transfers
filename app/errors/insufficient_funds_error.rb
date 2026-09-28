# frozen_string_literal: true

# The whole bulk is refused; details: { required_amount_cents, available_balance_cents }.
class InsufficientFundsError < DomainError
  configure code: "insufficient_funds", http_status: :unprocessable_content, default_message: "Insufficient funds"
end
