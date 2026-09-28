# frozen_string_literal: true

class MissingIdempotencyKeyError < DomainError
  configure code: "missing_idempotency_key",
            http_status: :bad_request,
            default_message: "The Idempotency-Key header is required"
end
