# 5. Money representation

Status: Accepted (2026-09-28)

## Context

"Ensure you don't lose a cent" is an explicit requirement. The contract sends amounts as **decimal euro
strings** (`"14.5"`, `"61238"`), while the database stores integer cents. Binary floating point can't represent
most decimal fractions exactly (`0.1 + 0.2 != 0.3`), so any Float on the money path risks off-by-one-cent
errors that accumulate over hundreds of lines.

Parsing also has edge cases. Ruby's `BigDecimal("1e3")` is 1000, `BigDecimal(" 12")` is 12, and
`BigDecimal("Infinity")` is infinite. A client that sends a JSON number (`14.5` instead of `"14.5"`) has
already gone through a float in its own serializer, so the value may no longer be what was intended.

## Chosen

- Storage: `bigint` cents in columns named `*_cents`. Ruby holds Integer cents.
- Currency: EUR only, enforced by a DB `CHECK (amount_currency = 'EUR')` and a `Transaction::CURRENCY` constant.
- Parsing (`AmountParser`): the raw JSON value must be a **String**. It must match the whitelist
  `\A[0-9.]+\z`. It is then parsed with **lenient `BigDecimal`**. The result is rejected when it is
  unparseable, `<= 0`, has more than 2 decimals, or is above `MAX_AMOUNT_CENTS` (10^15).
- Leniency is deliberate: `"1.500"` (150 cents) and `".5"` (50 cents) are accepted.

## Discarded (why)

- **Floats**: rounding loses cents.
- **money-rails**: a gem for a single-currency problem that Integer cents already solve.
- **A strict regex grammar** (`\A\d+(\.\d{1,2})?\z`): the user preferred leniency for trailing zeros and a
  missing leading zero.
- **Bare `BigDecimal` without the whitelist**: accepts `"1e3"`, surrounding whitespace, `"Infinity"` and
  `"NaN"`.

## Consequences

- No Float appears on the money path. A spec covers the edge cases above, including JSON numbers.
- The per-item upper bound keeps every stored amount inside `bigint`. The bulk total is summed as a Ruby
  Integer (arbitrary precision) and is only persisted when it fits the balance, so it can't overflow either.
- A negative amount can't be expressed (`-` is outside the whitelist). Debits are made negative internally
  (decision 6).
