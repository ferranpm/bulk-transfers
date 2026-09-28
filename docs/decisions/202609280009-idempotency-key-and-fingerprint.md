# 9. Idempotency key and fingerprint

Status: Accepted (2026-09-28)

## Context

Crashes and network glitches can happen at any point:

- **Crash before commit**: the transaction rolls back and nothing was applied. A retry must be processed normally.
- **Crash or disconnect after commit, before the client reads the response**: the debit was applied, but the
  client can't know. If it retries and the server treats the retry as new, the account is debited twice.

The server can't tell a legitimate second payroll from a retry of the first by looking at the body: two
identical bulks can both be intended. The client has to say "this is the same request" with an explicit key.
Also, a buggy client might reuse a key for a *different* request, and that must not be silently treated as a
replay.

## Chosen

- A required `Idempotency-Key` header, 1–255 characters, opaque to the server. The README recommends a UUID.
  - Missing or blank → **400 `missing_idempotency_key`**.
  - Longer than 255 → **400 `invalid_idempotency_key`**.
- The key is **scoped per account**: `UNIQUE (bank_account_id, idempotency_key)`.
- **Fingerprint** = SHA-256 of the canonical JSON of the whitelisted params: keys sorted, `credit_transfers`
  order preserved, amounts exactly as sent. Unknown fields are ignored.
- Same key, same fingerprint → replay (decision 2). Same key, different fingerprint → **422
  `idempotency_key_reused`**.
- Only **successful** bulks are persisted. A request rejected for insufficient funds can be retried with the
  same key after the account is topped up.
- The key lookup happens **under the account lock** (decision 8), so two concurrent same-key requests are
  serialised. `RecordNotUnique` on insert is still rescued as a backstop that re-reads the row.

## Discarded (why)

- **Optional key**: no retry safety for clients that forget it.
- **UUID-only key**: needlessly strict. Clients may already have their own unique batch references.
- **Fingerprint of the raw body bytes**: a legitimate retry with different whitespace or key order would be
  rejected as `idempotency_key_reused`.
- **Persisting failures**: a client could never retry after fixing the cause (e.g. topping up the account).

## Consequences

- The header is an addition to the brief's contract. The README documents it.
- Keys never expire yet. A TTL cleanup job is listed under "Not built yet".
- Changing the order of `credit_transfers` changes the fingerprint on purpose, since the response order
  depends on it.
