# 10. Request validation

Status: Accepted (2026-09-28)

## Context

The OpenAPI contract only specifies success. Everything else (missing fields, wrong types, bad IBANs,
non-EUR currency) is left to us. Bulk clients send hundreds of lines. If the API stops at the first error,
fixing a file becomes one round trip per bad line.

Validation must also run **before** the account lock is taken (decision 8), so malformed requests never add
lock contention.

## Chosen

- Collect **all** errors into `details` as `[{ index:, field:, issue: }]`. `index` is the position in
  `credit_transfers` and is omitted for top-level fields. All of them are returned in one 422
  `validation_failed`.
- Rules:
  - Required fields present and strings.
  - `credit_transfers` is a non-empty array of objects.
  - Currency is `EUR` (otherwise `issue: "unsupported_currency"`).
  - BIC matches `\A[A-Z0-9]{8}([A-Z0-9]{3})?\z`.
  - IBAN matches `\A[A-Z]{2}\d{2}[A-Z0-9]{1,30}\z`.
  - `counterparty_name` ≤ 70 characters, `description` ≤ 140: the SEPA limits for name and remittance
    information, so an accepted transfer can be executed as is (see `schema-changes`).
  - Amount per `money-representation`.
- **No cap on bulk size.**
- All sample IBANs and BICs in the brief pass these patterns (verified).

## Discarded (why)

- **Fail fast on the first error**: poor developer experience for bulk clients.
- **Presence-only IBAN/BIC checks**: lets obvious garbage through.
- **Full mod-97 checksum via `ibandit`**: the right production answer, and the README recommends it, but it
  risks rejecting the synthetic sample data (e.g. the `XXXXX` account suffix).
- **Cap at 1,000 transfers**: the user chose no cap. The README documents the lock-duration and timeout risk.

## Consequences

- Validation is a pure value object (`BulkTransfers::Request`), unit-tested per rule, with no DB access.
- Very large bulks are accepted and hold the account lock longer. The statement timeout (decision 13) bounds
  the worst case.
- A non-EUR currency is a field error inside `validation_failed`, not a separate error code.
