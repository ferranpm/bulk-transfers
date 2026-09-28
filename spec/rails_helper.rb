# frozen_string_literal: true

require "spec_helper"
# Assignment, not ||=: compose exports RAILS_ENV=development into the container,
# and running specs against the development database would wipe it.
ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Rails.root.glob("spec/support/**/*.rb").sort.each { |support_file| require support_file }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]
  config.use_transactional_fixtures = true
  config.include FactoryBot::Syntax::Methods
  config.filter_rails_from_backtrace!
end
