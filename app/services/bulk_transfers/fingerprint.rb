# frozen_string_literal: true

module BulkTransfers
  # Identifies "the same request" behind an Idempotency-Key. Hashing canonical JSON of the whitelisted params,
  # not the raw bytes, keeps a legitimate retry with other whitespace, key order or extra fields a replay, while
  # any change in the order of credit transfers or in a value (amount strings included) makes it a different
  # request (PLAN idempotency-key-and-fingerprint).
  #   BulkTransfers::Fingerprint.call(request) # => "3f0a...", 64 hex characters
  module Fingerprint
    module_function

    def call(request) = Digest::SHA256.hexdigest(JSON.generate(canonical(request.fingerprint_params)))

    def canonical(value)
      case value
      when Hash then value.to_h { |key, nested_value| [key.to_s, canonical(nested_value)] }.sort.to_h
      when Array then value.map { |element| canonical(element) }
      else value
      end
    end
  end
end
