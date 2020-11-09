require 'uuidtools'

module Resque
  # A Resque::Job represents a unit of work. Each job lives on a
  # single queue and has an associated payload object. The payload
  # is a hash with two attributes: `class` and `args`. The `class` is
  # the name of the Ruby class which should be used to run the
  # job. The `args` are an array of arguments which should be passed
  # to the Ruby class's `perform` class-level method.
  #
  # You can manually run a job using this code:
  #
  #   job = Resque::Job.reserve(:high)
  #   klass = Resque::Job.constantize(job.payload['class'])
  #   klass.perform(*job.payload['args'])
  class Job
    include Helpers
    extend Helpers
    def redis
      Resque.redis
    end
    alias data_store redis

    def self.redis
      Resque.redis
    end

    def self.data_store
      redis
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

    # Given a Ruby object, returns a string suitable for storage in a
    # queue.
    def self.encode(object)
      Resque.encode(object)
    end

    # Given a string, returns a Ruby object.
    def self.decode(object)
      Resque.decode(object)
    end

    # Given a word with dashes, returns a camel cased version of it.
    def classify(dashed_word)
      Resque.classify(dashed_word)
    end

    # Tries to find a constant with the name specified in the argument string
    def constantize(camel_cased_word)
      Resque.constantize(camel_cased_word)
    end

    # Raise Resque::Job::DontPerform from a before_perform hook to
    # abort the job.
    DontPerform = Class.new(StandardError)

    # The worker object which is currently processing this job.
    attr_accessor :worker

    # The name of the queue from which this job was pulled (or is to be
    # placed)
    attr_reader :queue

    # This job's associated payload object.
    attr_reader :payload

    # Do not add failed jobs to the failed queue
    attr_reader :skip_failed_queue

    def initialize(queue, payload)
      @queue = queue
      @payload = payload
      @failure_hooks_ran = false
    end

    def id
      @payload['id']
    end

    def generation
      @payload['generation']
    end

    # Creates a job by placing it on a queue. Expects a string queue
    # name, a string class name, and an optional array of arguments to
    # pass to the class' `perform` method.
    #
    # Raises an exception if no queue or class is given.
    def self.create(queue, klass, *args)
      create_extended(queue, klass, new_uuid, 1, *args)
    end

    def self.create_extended(queue, klass, id, generation, *args)
      Resque.validate(klass, queue)

      if Resque.inline?
        new(:inline, {
              'class' => klass,
              'args' => decode(encode(args)),
              'id' => id,
              'generation' => generation
            }).perform
      else
        Resque.push(queue, {
                      class: klass.to_s,
                      args: args,
                      id: id,
                      generation: generation
                    })
      end
    end

    def self.new_uuid
      UUIDTools::UUID.random_create.hexdigest.to_s
    end

    # Removes a job from a queue. Expects a string queue name, a
    # string class name, and, optionally, args.
    #
    # Returns the number of jobs destroyed.
    #
    # If no args are provided, it will remove all jobs of the class
    # provided.
    #
    # That is, for these two jobs:
    #
    # { 'class' => 'UpdateGraph', 'args' => ['defunkt'] }
    # { 'class' => 'UpdateGraph', 'args' => ['mojombo'] }
    #
    # The following call will remove both:
    #
    #   Resque::Job.destroy(queue, 'UpdateGraph')
    #
    # Whereas specifying args will only remove the 2nd job:
    #
    #   Resque::Job.destroy(queue, 'UpdateGraph', 'mojombo')
    #
    # This method can be potentially very slow and memory intensive,
    # depending on the size of your queue, as it loads all jobs into
    # a Ruby array before processing.
    def self.destroy(queue, klass, *args)
      klass = klass.to_s
      queue = "queue:#{queue}"
      destroyed = 0

      redis.lrange(queue, 0, -1).each do |string|
        ob = decode(string)
        if ob['class'] == klass &&
           (args.empty? || args == ob['args'])
          destroyed += redis.lrem(queue, 0, string).to_i
        end
      end

      destroyed
    end

    # Given a string queue name, returns an instance of Resque::Job
    # if any jobs are available. If not, returns nil.
    def self.reserve(queue)
      return unless payload = Resque.pop(queue)

      new(queue, payload)
    end

    # Attempts to perform the work represented by this job instance.
    # Calls #perform on the class given in the payload with the
    # arguments given in the payload.
    def perform
      job = payload_class
      job_args = args || []
      job_was_performed = false

      begin
        # Execute before_perform hook. Abort the job gracefully if
        # Resque::DontPerform is raised.
        begin
          before_hooks.each do |hook|
            job.send(hook, *job_args)
          end
        rescue DontPerform
          return false
        end

        # Execute the job. Do it in an around_perform hook if available.
        if around_hooks.empty?
          job.perform(*job_args)
          job_was_performed = true
        else
          # We want to nest all around_perform plugins, with the last one
          # finally calling perform
          stack = around_hooks.reverse.inject(nil) do |last_hook, hook|
            if last_hook
              lambda do
                job.send(hook, *job_args) { last_hook.call }
              end
            else
              lambda do
                job.send(hook, *job_args) do
                  result = job.perform(*job_args)
                  job_was_performed = true
                  result
                end
              end
            end
          end
          stack.call
        end

        # Execute after_perform hook
        after_hooks.each do |hook|
          job.send(hook, *job_args)
        end

        # Return true if the job was performed
        job_was_performed

      # If an exception occurs during the job execution, look for an
      # on_failure hook then re-raise.
      rescue Object => e
        run_failure_hooks(e)
        raise e
      end
    end

    # Returns the actual class constant represented in this job's payload.
    def payload_class
      @payload_class ||= constantize(@payload['class'])
    end

    # Returns the payload class as a string without raising NameError
    def payload_class_name
      payload_class.to_s
    rescue NameError
      'No Name'
    end

    def has_payload_class?
      payload_class != Object
    rescue NameError
      false
    end

    # Returns an array of args represented in this job's payload.
    def args
      @payload['args']
    end

    # Given an exception object, hands off the needed parameters to
    # the Failure module.
    def fail(exception)
      run_failure_hooks(exception)
    rescue Exception => e
      raise e
    ensure
      unless skip_failed_queue
        Failure.create(
          payload: payload,
          exception: exception,
          worker: worker,
          queue: queue
        )
      end
    end

    # Creates an identical job, essentially placing this job back on
    # the queue.
    def recreate
      self.class.create_extended(queue, payload_class, id, generation + 1, *args)
    end

    # String representation
    def inspect
      obj = @payload
      format('(Job{%s} | %s | %s)', @queue, obj['class'], obj['args'].inspect)
    end

    # Equality
    def ==(other)
      queue == other.queue &&
        payload_class == other.payload_class &&
        args == other.args
    end

    def before_hooks
      @before_hooks ||= Plugin.before_hooks(payload_class)
    end

    def around_hooks
      @around_hooks ||= Plugin.around_hooks(payload_class)
    end

    def after_hooks
      @after_hooks ||= Plugin.after_hooks(payload_class)
    end

    def failure_hooks
      @failure_hooks ||= Plugin.failure_hooks(payload_class)
    end

    def run_failure_hooks(exception)
      job_args = args || []
      if has_payload_class?
        failure_hooks.each { |hook| payload_class.send(hook, exception, *job_args) } unless @failure_hooks_ran
      end
    rescue Exception => e
      error_message = "Additional error (#{e.class}: #{e}) occurred in running failure hooks for job #{inspect}\n" \
                      "Original error that caused job failure was #{e.class}: #{exception.class}: #{exception.message}"
      raise error_message
    ensure
      @failure_hooks_ran = true
    end
  end
end
