# frozen_string_literal: true

# Run using bin/ci. This is the single validity gate for the project (decision 18).

CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn"
  step "Tests: Prepare DB", "bin/rails db:test:prepare"
  step "Tests: RSpec", "bin/rspec --format progress"
end
