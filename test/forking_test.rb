require 'test_helper'
require 'tmpdir'

describe "Resque::Worker" do

  class FastJob
    @queue = :jobs

    def self.perform
      Resque.redis.reconnect # get its own connection
      Resque.redis.rpush('fastjob', "#{Process.pid}")
    end
  end

  def start_worker
    Resque.enqueue FastJob

    worker_pid = Kernel.fork do
      Resque.redis.reconnect
      worker = Resque::Worker.new(:jobs)
      worker.jobs_per_fork = 16
      worker.worker_count = 1
      worker.thread_count = 1
      worker.work
    end

    child_pid = Resque.redis.blpop('fastjob', 5)
    refute_nil child_pid
    worker_pid
  end

  it "forks properly and whatnot" do
    master_pid = start_worker
    worker_pids = {}
    worker_tids = {}

    47.times { # one job is used by the startup
      Resque.enqueue FastJob
      name, pid_tid = Resque.redis.blpop('fastjob', 5)
      refute_nil pid_tid
      pid, tid = pid_tid.split(":")
      worker_pids[pid] = true
      worker_tids[tid] = true
    }
    Process.kill('TERM', master_pid)
    Process.waitpid(master_pid)
    assert_equal 3, worker_pids.size
  end
end
