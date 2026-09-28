# frozen_string_literal: true

# Malformed JSON and a non-JSON Content-Type both mean we couldn't read the body (PLAN non-json-requests).
class InvalidJsonError < DomainError
  configure code: "invalid_json",
            http_status: :bad_request,
            default_message: "The request body must be a JSON document sent as application/json"
end
