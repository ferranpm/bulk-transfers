# frozen_string_literal: true

module Api
  # JSON-only base: no CSRF, cookies or views, while the app keeps the full Rails stack (PLAN keep-full-rails-stack).
  # Every error leaves as the one envelope
  # { error: { code, message, details } } (PLAN error-model).
  class BaseController < ActionController::API
    # The controllers read the raw body keys themselves; wrapping would only add a duplicate nested copy.
    wrap_parameters false

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render_error(InvalidJsonError.new)
    end

    private

    def render_error(error)
      # Nothing was applied, so the client may retry right away (PLAN timeouts-and-unavailability).
      response.set_header("Retry-After", "1") if error.is_a?(ServiceUnavailableError)
      render json: error.to_h, status: error.http_status
    end
  end
end
