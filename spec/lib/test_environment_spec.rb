# frozen_string_literal: true

RSpec.describe "TestEnvironment" do
  it "runs specs in the test environment" do
    expect(Rails.env).to be_test
  end

  it "applies the configured lock_timeout to database connections" do
    configured_lock_timeout = ActiveRecord::Base.connection_db_config.configuration_hash.fetch(:variables).fetch("lock_timeout")

    applied_lock_timeout = ActiveRecord::Base.connection.select_value("SHOW lock_timeout")

    expect(applied_lock_timeout).to eq(configured_lock_timeout)
  end

  context "when tagged :concurrency", :concurrency do
    it "runs outside a wrapping test transaction" do
      open_transactions = ActiveRecord::Base.connection.open_transactions

      expect(open_transactions).to eq(0)
    end
  end
end
