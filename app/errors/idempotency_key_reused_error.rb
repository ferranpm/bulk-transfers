# frozen_string_literal: true

# Same key, different fingerprint: never treated as a replay (PLAN idempotency-key-and-fingerprint).
class IdempotencyKeyReusedError < DomainError
  configure code: "idempotency_key_reused",
            http_status: :unprocessable_content,
            default_message: "The Idempotency-Key was already used for a different request"
end
