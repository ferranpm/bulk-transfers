# frozen_string_literal: true

module BulkTransfers
  # The one use case of the service: apply a bulk of credit transfers atomically, or nothing at all
  # (PLAN operations-and-result). It never raises to the caller; every outcome is a frozen Result.
  #   BulkTransfers::Create.call(organization_iban:, organization_bic:, credit_transfers:, idempotency_key:)
  #   # => Result.success(bulk_transfer, idempotent_replay:) or Result.failure(DomainError)
  class Create
    # Transient failures where nothing was applied, so the client can safely retry (PLAN timeouts-and-unavailability).
    INFRASTRUCTURE_ERRORS = [
      ActiveRecord::LockWaitTimeout,
      ActiveRecord::Deadlocked,
      ActiveRecord::QueryCanceled,
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::ConnectionFailed,
      ActiveRecord::ConnectionTimeoutError
    ].freeze

    def self.call(...) = new(...).call

    def initialize(organization_iban:, organization_bic:, credit_transfers:, idempotency_key:)
      @raw_params = { organization_iban:, organization_bic:, credit_transfers: }
      @idempotency_key = idempotency_key
      @started_at = monotonic_milliseconds
    end

    def call
      # Parsed before the lock, so a malformed request never adds contention.
      request = Request.parse(**@raw_params)
      @fingerprint = Fingerprint.call(request)
      apply(request)
    rescue ActiveRecord::RecordNotUnique
      # Backstop only: the account row lock serialises every request for this account, so the idempotency
      # lookup under the lock sees any committed bulk with this key and the unique index can't be hit. If the
      # locking ever changes, the index still refuses a second bulk and the request resolves as a replay or a
      # reuse. Rescued outside the transaction because the failed INSERT has aborted its savepoint.
      resolve_duplicate_key
    rescue DomainError => e
      reject(e)
    rescue *INFRASTRUCTURE_ERRORS => e
      StructuredLog.info("bulk_transfer.unavailable", error_class: e.class.name, duration_ms:)
      Result.failure(ServiceUnavailableError.new)
    end

    private

    def apply(request)
      ActiveRecord::Base.transaction(requires_new: true) do
        account = BankAccount.lock.find_by(iban: request.organization_iban, bic: request.organization_bic)
        raise AccountNotFoundError if account.nil?

        existing_bulk_transfer = account.bulk_transfers.find_by(idempotency_key: @idempotency_key)
        next replay_or_reject(existing_bulk_transfer) if existing_bulk_transfer

        ensure_funds!(account, request)
        accept(account, request)
      end
    end

    # The first of three overdraft guards: checked under the lock, before anything is written.
    def ensure_funds!(account, request)
      return if account.balance_cents >= request.total_amount_cents

      raise InsufficientFundsError.new(
        details: { required_amount_cents: request.total_amount_cents, available_balance_cents: account.balance_cents }
      )
    end

    def accept(account, request)
      bulk_transfer = account.bulk_transfers.create!(
        idempotency_key: @idempotency_key, request_fingerprint: @fingerprint,
        transfer_count: request.transfer_count, total_amount_cents: request.total_amount_cents
      )
      Ledger.debit!(account:, bulk_transfer:, credit_transfers: request.credit_transfers)
      StructuredLog.info(
        "bulk_transfer.accepted", bank_account_id: account.id, bulk_transfer_id: bulk_transfer.id,
                                  transfer_count: bulk_transfer.transfer_count,
                                  total_amount_cents: bulk_transfer.total_amount_cents, duration_ms:
      )
      Result.success(bulk_transfer)
    end

    def replay_or_reject(bulk_transfer)
      raise IdempotencyKeyReusedError unless bulk_transfer.request_fingerprint == @fingerprint

      StructuredLog.info("bulk_transfer.replayed", bank_account_id: bulk_transfer.bank_account_id,
                                                   bulk_transfer_id: bulk_transfer.id, duration_ms:)
      Result.success(bulk_transfer, idempotent_replay: true)
    end

    def resolve_duplicate_key
      bulk_transfer = BulkTransfer.joins(:bank_account).find_by!(
        idempotency_key: @idempotency_key,
        bank_account: { iban: @raw_params[:organization_iban], bic: @raw_params[:organization_bic] }
      )
      replay_or_reject(bulk_transfer)
    rescue DomainError => e
      reject(e)
    end

    def reject(error)
      StructuredLog.info("bulk_transfer.rejected", reason: error.code, duration_ms:)
      Result.failure(error)
    end

    def duration_ms = monotonic_milliseconds - @started_at

    def monotonic_milliseconds = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
