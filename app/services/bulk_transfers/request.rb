# frozen_string_literal: true

module BulkTransfers
  # Immutable, validated view of a bulk request. Built before the account lock is taken, so a malformed
  # request never adds lock contention, and it reports every problem at once (PLAN request-validation).
  #   BulkTransfers::Request.parse(organization_iban:, organization_bic:, credit_transfers:)
  #   # => Request, or raises ValidationFailedError with details [{ index?, field, issue }]
  class Request
    # `amount` is kept exactly as sent because the fingerprint hashes the input, not our reading of it.
    CreditTransfer = Data.define(
      :amount, :amount_cents, :currency, :counterparty_name, :counterparty_iban, :counterparty_bic, :description
    )

    IBAN_FORMAT = /\A[A-Z]{2}\d{2}[A-Z0-9]{1,30}\z/
    BIC_FORMAT = /\A[A-Z0-9]{8}([A-Z0-9]{3})?\z/
    TEXT_FIELD_RULES = {
      "counterparty_name" => { max_length: Transaction::NAME_MAX_LENGTH },
      "counterparty_iban" => { format: IBAN_FORMAT },
      "counterparty_bic" => { format: BIC_FORMAT },
      "description" => { max_length: Transaction::DESCRIPTION_MAX_LENGTH }
    }.freeze
    CREDIT_TRANSFER_FIELDS = ["amount", "currency", *TEXT_FIELD_RULES.keys].freeze

    attr_reader :organization_iban, :organization_bic, :credit_transfers

    class << self
      def parse(organization_iban:, organization_bic:, credit_transfers:)
        errors = [
          field_error("organization_iban", text_issue(organization_iban, format: IBAN_FORMAT)),
          field_error("organization_bic", text_issue(organization_bic, format: BIC_FORMAT)),
          *list_errors(credit_transfers)
        ].compact
        raise ValidationFailedError.new(details: errors) if errors.any?

        new(organization_iban:, organization_bic:, credit_transfers: credit_transfers.map { build_credit_transfer(it) })
      end

      private

      def list_errors(credit_transfers)
        return [field_error("credit_transfers", "missing")] if credit_transfers.nil?
        return [field_error("credit_transfers", "must_be_an_array")] unless credit_transfers.is_a?(Array)
        return [field_error("credit_transfers", "must_not_be_empty")] if credit_transfers.empty?

        credit_transfers.each_with_index.flat_map { |credit_transfer, index| item_errors(credit_transfer, index) }
      end

      def item_errors(credit_transfer, index)
        return [{ index:, field: "credit_transfers", issue: "must_be_an_object" }] unless credit_transfer.is_a?(Hash)

        issues = {
          "amount" => amount_issue(credit_transfer["amount"]),
          "currency" => currency_issue(credit_transfer["currency"]),
          **TEXT_FIELD_RULES.to_h { |field, rules| [field, text_issue(credit_transfer[field], **rules)] }
        }
        issues.filter_map { |field, issue| { index:, field:, issue: } if issue }
      end

      def field_error(field, issue) = issue && { field:, issue: }

      def text_issue(value, format: nil, max_length: nil)
        type_issue(value) || content_issue(value, format:, max_length:)
      end

      def type_issue(value)
        return "missing" if value.nil?

        "must_be_a_string" unless value.is_a?(String)
      end

      def content_issue(text, format:, max_length:)
        return "blank" if text.blank?
        return "too_long" if max_length && text.length > max_length

        "invalid_format" if format && !format.match?(text)
      end

      def currency_issue(currency)
        text_issue(currency) || ("unsupported_currency" unless currency == Transaction::CURRENCY)
      end

      def amount_issue(amount) = amount.nil? ? "missing" : AmountParser.parse(amount).issue

      def build_credit_transfer(credit_transfer)
        fields = credit_transfer.slice(*CREDIT_TRANSFER_FIELDS).symbolize_keys
        CreditTransfer.new(**fields, amount_cents: AmountParser.parse(fields[:amount]).amount_cents)
      end
    end

    def initialize(organization_iban:, organization_bic:, credit_transfers:)
      @organization_iban = organization_iban
      @organization_bic = organization_bic
      @credit_transfers = credit_transfers.freeze
      freeze
    end

    def transfer_count = credit_transfers.size

    # Integer arithmetic: arbitrary precision, so the sum can't overflow (PLAN money-representation).
    def total_amount_cents = credit_transfers.sum(&:amount_cents)

    # The whitelisted input with amounts as sent: what the fingerprint hashes (PLAN idempotency-key-and-fingerprint).
    def fingerprint_params
      {
        "organization_iban" => organization_iban,
        "organization_bic" => organization_bic,
        "credit_transfers" => credit_transfers.map do |credit_transfer|
          credit_transfer.to_h.except(:amount_cents).stringify_keys
        end
      }
    end
  end
end
