# frozen_string_literal: true

class InvalidIdempotencyKeyError < DomainError
  configure code: "invalid_idempotency_key", http_status: :bad_request,
            default_message: "The Idempotency-Key header must be at most 255 characters"
end
