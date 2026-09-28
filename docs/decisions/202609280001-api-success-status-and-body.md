# 1. API success status and body

Status: Accepted (2026-09-28)

## Context

`POST /transfers/bulk` debits one account for a list of credit transfers. The brief contradicts itself about
the success response. The prose says to "add the transfers to the database, update the customer's balance,
and return a 201 HTTP response". The OpenAPI contract in the same document, and the shorter version of the
brief, declare `'204': Bulk transfer request created successfully` with no body.

The choice matters beyond style. A payroll client submits hundreds of transfers in one call, and then needs
to reconcile each line of its own file against what the bank created: which transaction id belongs to which
employee. With a bodiless 204, the only way to learn that is a second, not-yet-existing read endpoint, and the
client would have to match rows back to its input by value, which is ambiguous when two lines are identical
(two employees paid the same amount under the same description).

## Chosen

**201 Created** with a JSON body describing the bulk and every transaction it created:

```json
{ "bulk_transfer": { "id": 1, "transfer_count": 3, "total_amount_cents": 6225150,
  "created_at": "...", "credit_transfers": [ { "id": 3, "amount_cents": 1450, ... } ] } }
```

`credit_transfers` are returned in request order (see `bulk-insert-strategy`), so item *i* of the response is
item *i* of the request. The conflict with the OpenAPI block is documented in the README.

## Discarded (why)

- **204 with no body**: matches the OpenAPI block, but the client cannot map its items to the created
  transaction ids.
- **201 with only the bulk id**: same mapping problem, one step removed.
- **Including the resulting balance in the body**: the value is stale as soon as another bulk commits, and an
  idempotent replay (decision 2) would return a number that no longer matches the account.

## Consequences

- We knowingly deviate from the OpenAPI `204`. A reviewer comparing against the contract will see a different
  status. The README explains why.
- The body must be rebuildable from the database alone, so that a replay can return the same payload
  (decision 2). A presenter object builds it from the persisted bulk and its transactions.
- Amounts are returned in integer cents, not the request's decimal euro strings, to avoid ambiguity.
