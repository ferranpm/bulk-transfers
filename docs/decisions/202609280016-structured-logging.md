# 16. Structured logging

Status: Accepted (2026-09-28)

## Context

With several instances, the logs are the first place to answer "what happened to this bulk?", "how often do
clients hit insufficient funds?" or "are we returning 503s?". Free-text log lines are hard to aggregate or
alert on. The requests also contain personal and banking data (names, IBANs) that must not end up in logs.

## Chosen

- A small `StructuredLog` module emits single-line `event=<name> key=value ...` entries (values quoted when
  they contain spaces).
- Events:
  - `bulk_transfer.accepted` (account id, transfer count, total cents, `duration_ms`)
  - `bulk_transfer.rejected` (reason code)
  - `bulk_transfer.replayed`
  - `bulk_transfer.unavailable`
- Never logged: IBANs, request bodies, idempotency keys.

## Discarded (why)

- **lograge / semantic_logger**: a gem for about 20 lines.

## Consequences

- Log lines are grep-friendly and parseable by any log pipeline.
- Metrics and tracing (Prometheus, OpenTelemetry) are listed under "Not built yet". They can be derived from
  these events.
