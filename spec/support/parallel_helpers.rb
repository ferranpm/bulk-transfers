# frozen_string_literal: true

# Runs the block in `count` real threads, each on its own connection, released together by a start gate so the
# requests genuinely overlap instead of running one after another as the threads happen to boot.
#   results = run_in_parallel(8) { |index| BulkTransfers::Create.call(...) } # => results in index order
module ParallelHelpers
  START_GATE_TIMEOUT_SECONDS = 5

  def run_in_parallel(count)
    ready = Concurrent::CountDownLatch.new(count)
    start_gate = Concurrent::CountDownLatch.new(1)
    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.verify! # check the connection out and open it before the gate, not after it
          ready.count_down
          start_gate.wait(START_GATE_TIMEOUT_SECONDS)
          yield index
        end
      end
    end
    raise "the threads never became ready" unless ready.wait(START_GATE_TIMEOUT_SECONDS)

    start_gate.count_down
    threads.map(&:value)
  end
end

RSpec.configure do |config|
  config.include ParallelHelpers, :concurrency
end
