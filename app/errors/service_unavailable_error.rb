# frozen_string_literal: true

# Transient infrastructure failure with nothing applied; safe to retry (PLAN timeouts-and-unavailability).
class ServiceUnavailableError < DomainError
  configure code: "service_unavailable", http_status: :service_unavailable,
            default_message: "The service is temporarily unavailable, please retry"
end
