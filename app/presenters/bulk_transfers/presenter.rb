# frozen_string_literal: true

module BulkTransfers
  # The success body, shared by the 201 and the 200 replay so both are byte-for-byte the same shape.
  # Amounts are shown positive, as the client sent them; the ledger stores debits negative.
  #   BulkTransfers::Presenter.new(bulk_transfer).as_json # => { bulk_transfer: { id:, ..., credit_transfers: [...] } }
  class Presenter
    def initialize(bulk_transfer)
      @bulk_transfer = bulk_transfer
    end

    def as_json(*)
      {
        bulk_transfer: {
          id: @bulk_transfer.id,
          transfer_count: @bulk_transfer.transfer_count,
          total_amount_cents: @bulk_transfer.total_amount_cents,
          created_at: @bulk_transfer.created_at.utc.iso8601,
          credit_transfers: @bulk_transfer.transactions.order(:id).map { credit_transfer_json(it) }
        }
      }
    end

    private

    def credit_transfer_json(transaction)
      {
        id: transaction.id,
        amount_cents: -transaction.amount_cents,
        amount_currency: transaction.amount_currency,
        counterparty_name: transaction.counterparty_name,
        counterparty_iban: transaction.counterparty_iban,
        counterparty_bic: transaction.counterparty_bic,
        description: transaction.description
      }
    end
  end
end
