# 3. Keep the full Rails stack

Status: Accepted (2026-09-28)

## Context

The repository was generated as a full Rails 8.1 application (propshaft, Action View, browser-oriented
`ApplicationController < ActionController::Base`), together with a provided Docker setup. The service only
exposes a JSON endpoint. Browser concerns such as CSRF protection, sessions and cookies are irrelevant to it,
and CSRF protection would actively reject a JSON POST from a non-browser client.

## Chosen

Keep the generated application as-is. API controllers inherit from a dedicated
`Api::BaseController < ActionController::API`, which has no CSRF, session or cookie middleware, and centralises
JSON error rendering.

## Discarded (why)

- **Convert to `config.api_only = true`**: churn in generated files and middleware for no functional gain in
  this exercise.
- **Regenerate with `rails new --api`**: throws away the provided Docker setup.
- **Inherit from `ApplicationController` and call `skip_forgery_protection`**: easy to forget on the next
  controller, and it still drags browser concerns into the API path.

## Consequences

- The app still carries unused assets and layout files. They are harmless and untouched.
- Every API controller must inherit from `Api::BaseController`. That is where parse errors and `DomainError`s
  are turned into the error envelope (decision 14).
