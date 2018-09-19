require 'test_helper'
require 'tmpdir'

describe "Resque::Worker" do

  class LongRunningJob
    @queue = :long_running_job

    def self.perform( sleep_time, rescue_time=nil )
      Resque.redis.reconnect # get its own connection
      Resque.redis.rpush( 'sigterm-test:start', Process.pid )
      sleep sleep_time
      Resque.redis.rpush( 'sigterm-test:result', 'Finished Normally' )
    rescue Resque::TermException => e
      Resque.redis.rpush( 'sigterm-test:result', %Q(Caught TermException: #{e.inspect}))
      sleep rescue_time
    ensure
      Resque.redis.rpush( 'sigterm-test:ensure_block_executed', 'exiting.' )
    end
  end

  def start_worker(rescue_time, term_timeout = 1)
    Resque.enqueue LongRunningJob, 3, rescue_time

    worker_pid = Kernel.fork do
      # reconnect since we just forked
      Resque.redis.reconnect

      worker = Resque::Worker.new(:long_running_job)
      worker.term_timeout = term_timeout

      suppress_warnings do
        worker.work(0)
      end
      exit!
    end

    # ensure the worker is started
    start_status = Resque.redis.blpop( 'sigterm-test:start', 5 )
    refute_nil start_status
    child_pid = start_status[1].to_i
    assert child_pid > 0, "worker child process not created"

    Process.kill('TERM', worker_pid)
    Process.waitpid(worker_pid)
    result = Resque.redis.lpop('sigterm-test:result')
    [worker_pid, child_pid, result]
  end

  def assert_exception_caught(result)
    refute_nil result
    assert !result.start_with?('Finished Normally'), 'Job Finished normally.  (sleep parameter to LongRunningJob not long enough?)'
    assert result.start_with?("Caught TermException"), 'TermException exception not raised in child.'
  end

  def assert_child_not_running(child_pid)
    # ensure that the child pid is no longer running
    child_still_running = !(`ps -p #{child_pid.to_s} -o pid=`).empty?
    assert !child_still_running
  end

  it "kills off the child when killed" do
    _worker_pid, child_pid, result = start_worker(0, false)
    assert_nil result
    assert_child_not_running child_pid
  end
end
