# frozen_string_literal: true

# Real row locks held from a second connection, the way a request on another instance would hold them.
# Only meaningful in `:concurrency` groups: the account must be committed to be visible to that connection.
module AccountLockHelpers
  LOCK_ACQUIRED_TIMEOUT_SECONDS = 5

  def while_account_locked_elsewhere(bank_account)
    lock_acquired = Thread::Queue.new
    release_lock = Thread::Queue.new
    lock_holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          BankAccount.lock.find(bank_account.id)
          lock_acquired << true
          release_lock.pop
        end
      end
    end
    raise "the lock holder never acquired the lock" unless lock_acquired.pop(timeout: LOCK_ACQUIRED_TIMEOUT_SECONDS)

    yield
  ensure
    release_lock << true
    lock_holder.join
  end

  # database.yml reads DB_LOCK_TIMEOUT at boot, so a spec shortens the wait with SET LOCAL, scoped to a wrapping
  # transaction. The operation's own transaction(requires_new: true) becomes a savepoint inside it.
  def with_lock_timeout(duration)
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.with_connection do |connection|
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(duration)}")
      end
      yield
    end
  end
end

RSpec.configure do |config|
  config.include AccountLockHelpers, :concurrency
end
