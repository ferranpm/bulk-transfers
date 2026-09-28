# frozen_string_literal: true

# One grep-friendly line per event, parseable by any log pipeline (PLAN structured-logging).
# Callers must never pass IBANs, request bodies or idempotency keys.
#   StructuredLog.info("bulk_transfer.accepted", bank_account_id: 1, duration_ms: 12)
#   # => "event=bulk_transfer.accepted bank_account_id=1 duration_ms=12"
module StructuredLog
  NEEDS_QUOTES = /[\s"=]/

  module_function

  def info(event, **fields) = Rails.logger.info(format(event, **fields))

  def format(event, **fields)
    { event: }.merge(fields).map { |key, value| "#{key}=#{format_value(value)}" }.join(" ")
  end

  def format_value(value)
    text = value.to_s
    text.empty? || text.match?(NEEDS_QUOTES) ? text.inspect : text
  end
end
