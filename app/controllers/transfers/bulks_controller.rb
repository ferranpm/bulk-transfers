# frozen_string_literal: true

module Transfers
  # POST /transfers/bulk. Thin on purpose: checks the transport (header, content type), hands the whitelisted
  # body to the operation and renders its Result (PLAN §3 for the full contract).
  class BulksController < Api::BaseController
    PERMITTED_FIELDS = %w[organization_iban organization_bic credit_transfers].freeze

    def create
      error = idempotency_key_error || content_type_error
      return render_error(error) if error

      result = BulkTransfers::Create.call(idempotency_key:, **permitted_body)
      return render_error(result.errors.sole) if result.failed?

      # 201 with a body so the client can map each line to its transfer id; 200 marks a replay of the same
      # body (PLAN api-success-status-and-body, PLAN idempotent-replay-response).
      render json: BulkTransfers::Presenter.new(result.value).as_json,
             status: result.idempotent_replay? ? :ok : :created
    end

    private

    def idempotency_key = request.headers["Idempotency-Key"]

    def idempotency_key_error
      return MissingIdempotencyKeyError.new if idempotency_key.blank?

      InvalidIdempotencyKeyError.new if idempotency_key.length > BulkTransfer::IDEMPOTENCY_KEY_MAX_LENGTH
    end

    def content_type_error
      InvalidJsonError.new unless request.media_type == Mime[:json].to_s
    end

    # Unknown keys are dropped here and inside each credit transfer by the Request. Strong parameters' permit is
    # not used because it silently drops values of the wrong type (a string where an array is expected, an object
    # where a string is expected), and the client should get a validation error for those instead.
    def permitted_body
      body = request.request_parameters
      PERMITTED_FIELDS.to_h { |field| [field.to_sym, body[field]] }
    end
  end
end
