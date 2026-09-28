# 2. Idempotent replay response

Status: Accepted (2026-09-28)

## Context

Any process or network hop can fail at any moment. The dangerous window is **after the database commit but
before the client reads the response**: the debit happened, but the client saw a timeout or a reset
connection and cannot tell whether the bulk was applied. Its only safe move is to retry with the same
`Idempotency-Key` (decision 9). The server must then recognise the retry, apply nothing, and still give the
client what it needs to reconcile, which is the body of the original success (decision 1).

The open question is which status that replay returns.

## Chosen

Same key and same request fingerprint → **200 OK** with **the same body** as the original 201. The body is
rebuilt from the persisted bulk and its transactions (no response snapshot is stored). A 200 tells the client
"this already exists, nothing new was created", which is literally true.

## Discarded (why)

- **Return an identical 201** (Stripe-style): a client that only checks for 2xx works either way, but support
  and debugging cannot tell from logs or client traces whether a request was the original or a replay. We
  prefer the replay to be visible.

## Consequences

- Clients must treat both 200 and 201 as success. The README states this.
- The body is deterministic for a given bulk: the same ids, amounts and order on every replay. A request spec
  asserts that the replay body equals the original.
- A replay emits its own log event (`bulk_transfer.replayed`), so replays are countable.
