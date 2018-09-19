require 'time'
require 'set'
require 'redis/distributed'

module Resque
  # A Resque Worker processes jobs. On platforms that support fork(2),
  # the worker will fork off a child to process each job. This ensures
  # a clean slate when beginning the next job and cuts down on gradual
  # memory growth as well as low level failures.
  #
  # It also ensures workers are always listening to signals from you,
  # their master, and can react accordingly.
  class Worker
    include Resque::Helpers
    extend Resque::Helpers
    include Resque::Logging

    attr_accessor :term_timeout, :jobs_per_fork, :worker_count, :thread_count
    attr_writer :hostname, :to_s, :pid

    @@all_heartbeat_threads = []
    def self.kill_all_heartbeat_threads
      @@all_heartbeat_threads.each(&:kill).each(&:join)
      @@all_heartbeat_threads = []
    end

    def redis
      Resque.redis
    end
    alias :data_store :redis

    def self.redis
      Resque.redis
    end

    def self.data_store
      Resque.redis
    end

    # Given a Ruby object, returns a string suitable for storage in a
    # queue.
    def encode(object)
      Resque.encode(object)
    end

    # Given a string, returns a Ruby object.
    def decode(object)
      Resque.decode(object)
    end

    # Returns an array of all worker objects.
    def self.all
      data_store.worker_ids.map { |id| find(id, :skip_exists => true) }.compact
    end

    # Returns an array of all worker objects currently processing
    # jobs.
    def self.working
      names = all
      return [] unless names.any?

      reportedly_working = {}

      begin
        reportedly_working = data_store.workers_map(names).reject do |key, value|
          value.nil? || value.empty?
        end
      rescue Redis::Distributed::CannotDistribute
        names.each do |name|
          value = data_store.get_worker_payload(name)
          reportedly_working[name] = value unless value.nil? || value.empty?
        end
      end

      reportedly_working.keys.map do |key|
        worker = find(key.sub("worker:", ''), :skip_exists => true)
        worker.job = worker.decode(reportedly_working[key])
        worker
      end.compact
    end

    # Returns a single worker object. Accepts a string id.
    def self.find(worker_id, options = {})
      skip_exists = options[:skip_exists]

      if skip_exists || exists?(worker_id)
        host, pid, queues_raw = worker_id.split(':')
        queues = queues_raw.split(',')
        worker = new(*queues)
        worker.hostname = host
        worker.to_s = worker_id
        worker.pid = pid.to_i
        worker
      else
        nil
      end
    end

    # Alias of `find`
    def self.attach(worker_id)
      find(worker_id)
    end

    # Given a string worker id, return a boolean indicating whether the
    # worker exists
    def self.exists?(worker_id)
      data_store.worker_exists?(worker_id)
    end

    # Workers should be initialized with an array of string queue
    # names. The order is important: a Worker will check the first
    # queue given for a job. If none is found, it will check the
    # second queue name given. If a job is found, it will be
    # processed. Upon completion, the Worker will again check the
    # first queue given, and so forth. In this way the queue list
    # passed to a Worker on startup defines the priorities of queues.
    #
    # If passed a single "*", this Worker will operate on all queues
    # in alphabetical order. Queues can be dynamically added or
    # removed without needing to restart workers using this method.
    #
    # Workers should have `#prepare` called after they are initialized
    # if you are running work on the worker.
    def initialize(*queues)
      @shutdown = nil
      @paused = nil
      @before_first_fork_hook_ran = false

      @heartbeat_thread = nil
      @heartbeat_thread_signal = nil

      @worker_thread = nil

      verbose_value = ENV['LOGGING'] || ENV['VERBOSE']
      self.verbose = verbose_value if verbose_value
      self.very_verbose = ENV['VVERBOSE'] if ENV['VVERBOSE']
      self.term_timeout = (ENV['RESQUE_TERM_TIMEOUT'] || 30.0).to_f
      self.jobs_per_fork = [ (ENV['JOBS_PER_FORK'] || 1).to_i, 1 ].max
      self.worker_count = [ (ENV['WORKER_COUNT'] || 1).to_i, 1 ].max
      self.thread_count = [ (ENV['THREAD_COUNT'] || 1).to_i, 1 ].max
      raise "Thread counts greater than 1 not yet supported (but coming soon)" if thread_count > 1

      self.queues = queues
    end

    # Daemonizes the worker if ENV['BACKGROUND'] is set and writes
    # the process id to ENV['PIDFILE'] if set. Should only be called
    # once per worker.
    def prepare
      if ENV['BACKGROUND']
        Process.daemon(true)
      end

      if ENV['PIDFILE']
        File.open(ENV['PIDFILE'], 'w') { |f| f << pid }
      end

      self.reconnect if ENV['BACKGROUND']
    end

    WILDCARDS = ['*', '?', '{', '}', '[', ']'].freeze

    def queues=(queues)
      queues = queues.empty? ? (ENV["QUEUES"] || ENV['QUEUE']).to_s.split(',') : queues
      @queues = queues.map { |queue| queue.to_s.strip }
      @has_dynamic_queues = WILDCARDS.any? {|char| @queues.join.include?(char) }
      validate_queues
    end

    # A worker must be given a queue, otherwise it won't know what to
    # do with itself.
    #
    # You probably never need to call this.
    def validate_queues
      if @queues.nil? || @queues.empty?
        raise NoQueueError.new("Please give each worker at least one queue.")
      end
    end

    # Returns a list of queues to use when searching for a job.
    # A splat ("*") means you want every queue (in alpha order) - this
    # can be useful for dynamically adding new queues.
    def queues
      if @has_dynamic_queues
        current_queues = Resque.queues
        @queues.map { |queue| glob_match(current_queues, queue) }.flatten.uniq
      else
        @queues
      end
    end

    def glob_match(list, pattern)
      list.select do |queue|
        File.fnmatch?(pattern, queue)
      end.sort
    end

    def work(interval = 0.1, &block)
      interval = Float(interval)
      startup
      @children = []
      (1..worker_count).map { fork_worker_child(interval, &block) }

      loop do
        break if shutdown?

        @children.each do |child|
          if Process.waitpid(child, Process::WNOHANG)
            @children.delete(child)
            fork_worker_child(interval, &block)
          end
        end

        break if interval.zero?
        sleep interval
      end

      unregister_worker
    rescue Exception => exception
      return if exception.class == SystemExit && !@children
      log_with_severity :error, "Worker Error: #{exception.inspect}"
      unregister_worker(exception)
    end

    def fork_worker_child(interval, &block)
      @children << fork {
        worker_child(interval, &block)
        exit!
      }
      srand # Reseed after child fork
      procline "Forked worker children #{@children.join(",")} at #{Time.now.to_i}"
    end

    def worker_child(interval, &block)
      jobs_processed = 0
      reconnect

      loop do
        if work_one_job(&block)
          jobs_processed += 1
        else
          break if interval.zero?
          log_with_severity :debug, "Sleeping for #{interval} seconds"
          procline paused? ? "Paused" : "Waiting for #{queues.join(',')}"
          sleep interval
        end
        break if jobs_processed >= jobs_per_fork
      end
    end

    def work_one_job(job = nil, &block)
      return false if paused?
      return false unless job ||= reserve

      working_on job
      procline "Processing #{job.queue} since #{Time.now.to_i} [#{job.payload_class_name}]"

      log_with_severity :info, "got: #{job.inspect}"
      job.worker = self

      begin
        Thread.new { perform(job, &block) }.join
      rescue Object => e
        report_failed_job(job, e)
      end

      done_working

      true
    end

    # Reports the exception and marks the job as failed
    def report_failed_job(job,exception)
      log_with_severity :error, "#{job.inspect} failed: #{exception.inspect}"
      begin
        job.fail(exception)
      rescue Object => exception
        log_with_severity :error, "Received exception when reporting failure: #{exception.inspect}"
      end
      begin
        failed!
      rescue Object => exception
        log_with_severity :error, "Received exception when increasing failed jobs counter (redis issue) : #{exception.inspect}"
      end
    end

    # Processes a given job.
    def perform(job)
      begin
        job.perform
      rescue Object => e
        report_failed_job(job,e)
      else
        log_with_severity :info, "done: #{job.inspect}"
      ensure
        yield job if block_given?
      end
    end

    # Attempts to grab a job off one of the provided queues. Returns
    # nil if no job can be found.
    def reserve
      queues.each do |queue|
        log_with_severity :debug, "Checking #{queue}"
        if job = Resque.reserve(queue)
          log_with_severity :debug, "Found job on #{queue}"
          return job
        end
      end

      nil
    rescue Exception => e
      log_with_severity :error, "Error reserving job: #{e.inspect}"
      log_with_severity :error, e.backtrace.join("\n")
      raise e
    end

    # Reconnect to Redis to avoid sharing a connection with the parent,
    # retry up to 3 times with increasing delay before giving up.
    def reconnect
      tries = 0
      begin
        data_store.reconnect
      rescue Redis::BaseConnectionError
        if (tries += 1) <= 3
          log_with_severity :error, "Error reconnecting to Redis; retrying"
          sleep(tries)
          retry
        else
          log_with_severity :error, "Error reconnecting to Redis; quitting"
          raise
        end
      end
    end

    # Runs all the methods needed when a worker begins its lifecycle.
    def startup
      $0 = "resque: Starting"

      register_signal_handlers
      start_heartbeat
      prune_dead_workers
      register_worker

      # Fix buffering so we can `rake resque:work > resque.log` and
      # get output from the child in there.
      $stdout.sync = true
    end

    # Registers the various signal handlers a worker responds to.
    #
    # TERM: Shutdown immediately, kill the current job immediately.
    #  INT: Shutdown immediately, kill the current job immediately.
    # QUIT: Shutdown after the current job has finished processing.
    # USR1: Kill the current job immediately, continue processing jobs.
    # USR2: Don't process any new jobs
    # CONT: Start processing jobs again after a USR2
    def register_signal_handlers
      trap('TERM') { shutdown; send_child_signal('TERM'); kill_worker }
      trap('INT')  { shutdown; send_child_signal('INT'); kill_worker }

      begin
        trap('QUIT') { shutdown; send_child_signal('QUIT') }
        trap('USR1') { send_child_signal('USR1'); unpause_processing; kill_worker }
        trap('USR2') { pause_processing; send_child_signal('USR2') }
        trap('CONT') { unpause_processing; send_child_signal('CONT') }
      rescue ArgumentError
        log_with_severity :warn, "Signals QUIT, USR1, USR2, and/or CONT not supported."
      end

      log_with_severity :debug, "Registered signals"
    end

    def send_child_signal(signal)
      if @children
        @children.each do |child|
          Process.kill(signal, child) rescue nil
        end
      end
    end

    def kill_worker
      @worker_thread.kill if @worker_thread
    end

    # Schedule this worker for shutdown. Will finish processing the
    # current job.
    def shutdown
      log_with_severity :info, 'Exiting...'
      @shutdown = true
    end

    # Kill the child and shutdown immediately.
    # If not forking, abort this process.
    def shutdown!
      shutdown
    end

    # Should this worker shutdown as soon as current job is finished?
    def shutdown?
      @shutdown
    end

    def heartbeat
      data_store.heartbeat(self)
    end

    def remove_heartbeat
      data_store.remove_heartbeat(self)
    end

    def heartbeat!(time = data_store.server_time)
      data_store.heartbeat!(self, time)
    end

    def self.all_heartbeats
      data_store.all_heartbeats
    end

    # Returns a list of workers that have sent a heartbeat in the past, but which
    # already expired (does NOT include workers that have never sent a heartbeat at all).
    def self.all_workers_with_expired_heartbeats
      workers = Worker.all
      heartbeats = Worker.all_heartbeats
      now = data_store.server_time

      workers.select do |worker|
        id = worker.to_s
        heartbeat = heartbeats[id]

        if heartbeat
          seconds_since_heartbeat = (now - Time.parse(heartbeat)).to_i
          seconds_since_heartbeat > Resque.prune_interval
        else
          false
        end
      end
    end

    def start_heartbeat
      remove_heartbeat

      @heartbeat_thread_signal = Resque::ThreadSignal.new

      @heartbeat_thread = Thread.new do
        loop do
          heartbeat!
          signaled = @heartbeat_thread_signal.wait_for_signal(Resque.heartbeat_interval)
          break if signaled
        end
      end

      @@all_heartbeat_threads << @heartbeat_thread
    end

    # are we paused?
    def paused?
      @paused
    end

    # Stop processing jobs after the current one has completed (if we're
    # currently running one).
    def pause_processing
      log_with_severity :info, "USR2 received; pausing job processing"
      @paused = true
    end

    # Start processing jobs again after a pause
    def unpause_processing
      log_with_severity :info, "CONT received; resuming job processing"
      @paused = false
    end

    # Looks for any workers which should be running on this server
    # and, if they're not, removes them from Redis.
    #
    # This is a form of garbage collection. If a server is killed by a
    # hard shutdown, power failure, or something else beyond our
    # control, the Resque workers will not die gracefully and therefore
    # will leave stale state information in Redis.
    #
    # By checking the current Redis state against the actual
    # environment, we can determine if Redis is old and clean it up a bit.
    def prune_dead_workers
      return unless data_store.acquire_pruning_dead_worker_lock(self, Resque.heartbeat_interval)

      all_workers = Worker.all

      unless all_workers.empty?
        known_workers = worker_pids
        all_workers_with_expired_heartbeats = Worker.all_workers_with_expired_heartbeats
      end

      all_workers.each do |worker|
        # If the worker hasn't sent a heartbeat, remove it from the registry.
        #
        # If the worker hasn't ever sent a heartbeat, we won't remove it since
        # the first heartbeat is sent before the worker is registred it means
        # that this is a worker that doesn't support heartbeats, e.g., another
        # client library or an older version of Resque. We won't touch these.
        if all_workers_with_expired_heartbeats.include?(worker)
          log_with_severity :info, "Pruning dead worker: #{worker}"
          worker.unregister_worker(PruneDeadWorkerDirtyExit.new(worker.to_s))
          next
        end

        host, pid, worker_queues_raw = worker.id.split(':')
        worker_queues = worker_queues_raw.split(",")
        unless @queues.include?("*") || (worker_queues.to_set == @queues.to_set)
          # If the worker we are trying to prune does not belong to the queues
          # we are listening to, we should not touch it.
          # Attempt to prune a worker from different queues may easily result in
          # an unknown class exception, since that worker could easily be even
          # written in different language.
          next
        end

        next unless host == hostname
        next if known_workers.include?(pid)

        log_with_severity :debug, "Pruning dead worker: #{worker}"
        worker.unregister_worker
      end
    end

    # Registers ourself as a worker. Useful when entering the worker
    # lifecycle on startup.
    def register_worker
      data_store.register_worker(self)
    end

    def kill_background_threads
      if @heartbeat_thread
        @heartbeat_thread_signal.signal
        @heartbeat_thread.join
      end
    end

    # Unregisters ourself as a worker. Useful when shutting down.
    def unregister_worker(exception = nil)
      # If we're still processing a job, make sure it gets logged as a
      # failure.
      if (hash = processing) && !hash.empty?
        job = Job.new(hash['queue'], hash['payload'])
        # Ensure the proper worker is attached to this job, even if
        # it's not the precise instance that died.
        job.worker = self
        begin
          job.fail(exception || DirtyExit.new("Job still being processed"))
        rescue RuntimeError => e
          log_with_severity :error, e.message
        end
      end

      kill_background_threads

      data_store.unregister_worker(self) do
        Stat.clear("processed:#{self}")
        Stat.clear("failed:#{self}")
      end
    rescue Exception => exception_while_unregistering
      message = exception_while_unregistering.message
      if exception
        message += "\nOriginal Exception (#{exception.class}): #{exception.message}"
        message += "\n  #{exception.backtrace.join("  \n")}" if exception.backtrace
      end
      fail(exception_while_unregistering.class,
           message,
           exception_while_unregistering.backtrace)
    end

    # Given a job, tells Redis we're working on it. Useful for seeing
    # what workers are doing and when.
    def working_on(job)
      data = encode \
        :queue   => job.queue,
        :run_at  => Time.now.utc.iso8601,
        :payload => job.payload
      data_store.set_worker_payload(self,data)
    end

    # Called when we are done working - clears our `working_on` state
    # and tells Redis we processed a job.
    def done_working
      data_store.worker_done_working(self) do
        processed!
      end
    end

    # How many jobs has this worker processed? Returns an int.
    def processed
      Stat["processed:#{self}"]
    end

    # Tell Redis we've processed a job.
    def processed!
      Stat << "processed"
      Stat << "processed:#{self}"
    end

    # How many failed jobs has this worker seen? Returns an int.
    def failed
      Stat["failed:#{self}"]
    end

    # Tells Redis we've failed a job.
    def failed!
      Stat << "failed"
      Stat << "failed:#{self}"
    end

    # What time did this worker start? Returns an instance of `Time`
    def started
      data_store.worker_start_time(self)
    end

    # Tell Redis we've started
    def started!
      data_store.worker_started(self)
    end

    # Returns a hash explaining the Job we're currently processing, if any.
    def job(reload = true)
      @job = nil if reload
      @job ||= decode(data_store.get_worker_payload(self)) || {}
    end
    attr_writer :job
    alias_method :processing, :job

    # Boolean - true if working, false if not
    def working?
      state == :working
    end

    # Boolean - true if idle, false if not
    def idle?
      state == :idle
    end

    # Returns a symbol representing the current worker state,
    # which can be either :working or :idle
    def state
      data_store.get_worker_payload(self) ? :working : :idle
    end

    # Is this worker the same as another worker?
    def ==(other)
      to_s == other.to_s
    end

    def inspect
      "#<Worker #{to_s}>"
    end

    # The string representation is the same as the id for this worker
    # instance. Can be used with `Worker.find`.
    def to_s
      @to_s ||= "#{hostname}:#{pid}:#{@queues.join(',')}"
    end
    alias_method :id, :to_s

    # chomp'd hostname of this worker's machine
    def hostname
      @hostname ||= Socket.gethostname
    end

    # Returns Integer PID of running worker
    def pid
      @pid ||= Process.pid
    end

    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def worker_pids
      if RUBY_PLATFORM =~ /solaris/
        solaris_worker_pids
      elsif RUBY_PLATFORM =~ /mingw32/
        windows_worker_pids
      else
        linux_worker_pids
      end
    end

    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def windows_worker_pids
      tasklist_output = `tasklist /FI "IMAGENAME eq ruby.exe" /FO list`.encode("UTF-8", Encoding.locale_charmap)
      tasklist_output.split($/).select { |line| line =~ /^PID:/ }.collect { |line| line.gsub(/PID:\s+/, '') }
    end

    # Find Resque worker pids on Linux and OS X.
    #
    def linux_worker_pids
      `ps -A -o pid,command | grep -E "[r]esque:work|[r]esque:\sStarting|[r]esque-[0-9]" | grep -v "resque-web"`.split("\n").map do |line|
        line.split(' ')[0]
      end
    end

    # Find Resque worker pids on Solaris.
    #
    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def solaris_worker_pids
      `ps -A -o pid,comm | grep "[r]uby" | grep -v "resque-web"`.split("\n").map do |line|
        real_pid = line.split(' ')[0]
        pargs_command = `pargs -a #{real_pid} 2>/dev/null | grep [r]esque | grep -v "resque-web"`
        if pargs_command.split(':')[1] == " resque-#{Resque::Version}"
          real_pid
        end
      end.compact
    end

    # Given a string, sets the procline ($0) and logs.
    # Procline is always in the format of:
    #   RESQUE_PROCLINE_PREFIXresque-VERSION: STRING
    def procline(string)
      $0 = "#{ENV['RESQUE_PROCLINE_PREFIX']}resque-#{Resque::Version}: #{string}"
      log_with_severity :debug, $0
    end

    def log(message)
      info(message)
    end

    def log!(message)
      debug(message)
    end


    attr_reader :verbose, :very_verbose

    def verbose=(value);
      if value && !very_verbose
        Resque.logger.formatter = VerboseFormatter.new
        Resque.logger.level = Logger::INFO
      elsif !value
        Resque.logger.formatter = QuietFormatter.new
      end

      @verbose = value
    end

    def very_verbose=(value)
      if value
        Resque.logger.formatter = VeryVerboseFormatter.new
        Resque.logger.level = Logger::DEBUG
      elsif !value && verbose
        Resque.logger.formatter = VerboseFormatter.new
        Resque.logger.level = Logger::INFO
      else
        Resque.logger.formatter = QuietFormatter.new
      end

      @very_verbose = value
    end

    private

    def log_with_severity(severity, message)
      Logging.log(severity, message)
    end
  end
end
