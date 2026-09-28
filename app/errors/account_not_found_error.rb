# frozen_string_literal: true

class AccountNotFoundError < DomainError
  configure code: "account_not_found", http_status: :unprocessable_content,
            default_message: "No account matches the organization IBAN and BIC"
end
