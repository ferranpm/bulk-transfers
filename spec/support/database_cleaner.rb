# frozen_string_literal: true

require "database_cleaner/active_record"

# Concurrency specs run real threads, each on its own connection. A wrapping
# test transaction would be invisible to those connections and would hide the
# row locks under test, so `:concurrency` groups commit for real and truncate
# afterwards.
module ConcurrencyDatabaseCleaning
  extend ActiveSupport::Concern

  PRESERVED_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  included do
    self.use_transactional_tests = false
  end
end

RSpec.configure do |config|
  config.include ConcurrencyDatabaseCleaning, :concurrency

  config.after(:each, :concurrency) do
    DatabaseCleaner[:active_record].clean_with(:truncation, except: ConcurrencyDatabaseCleaning::PRESERVED_TABLES)
  end
end
