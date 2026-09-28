# 11. Non-JSON requests

Status: Accepted (2026-09-28)

## Context

Rails parses a JSON body before the controller runs. When the body is malformed it raises
`ActionDispatch::Http::Parameters::ParseError`, which by default becomes an HTML 400 page. When the
`Content-Type` isn't JSON, Rails doesn't parse the body at all, and the controller sees empty params, which
would look like "all required fields are missing". A body that is valid JSON but not an object (`[]`, `"x"`,
`42`) is yet another case. Each needs a predictable answer in the API's error envelope.

## Chosen

- Malformed JSON **and** a missing or non-JSON `Content-Type` → **400 `invalid_json`**.
- A well-formed JSON body that isn't an object → **422 `validation_failed`**.

## Discarded (why)

- **415 Unsupported Media Type for a wrong Content-Type**: technically precise, but one more status to explain
  and handle for little client benefit. Both cases mean "we couldn't read your JSON".

## Consequences

- `Api::BaseController` rescues `ParseError`, and the controller checks the media type before reading params.
- Request specs cover both 400 cases and the non-object 422.
