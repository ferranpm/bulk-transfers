# frozen_string_literal: true

# Every field problem at once, in details: [{ index?, field, issue }] (PLAN request-validation).
class ValidationFailedError < DomainError
  configure code: "validation_failed", http_status: :unprocessable_content, default_message: "The request is invalid"
end
