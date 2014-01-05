#  Copyright 2013 Petr Chalupa <git+actress@pitr.ch>
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require 'thread'
require 'set'
require 'logger'
require 'English'
require 'algebrick'
require 'justified/standard_error'

# TODO report failures and restarts
# TODO reserved threads scale up/down the pool

#noinspection RubyConstantNamingConvention
module Actress
  include Algebrick::Types

  class Set < ::Set
    def shift
      return nil if empty?
      @hash.shift[0]
    end
  end

  class FutureAlreadySet < StandardError
  end

  class Future
    # `#future` will become resolved to `true` when ``#countdown!`` is called `count` times
    class CountDownLatch
      attr_reader :future

      def initialize(count, future = Future.new)
        raise ArgumentError if count < 0
        @count  = count
        @lock   = Mutex.new
        @future = future
      end

      def countdown!
        @lock.synchronize do
          @count -= 1 if @count > 0
          @future.resolve true if @count == 0 && !@future.ready?
        end
      end

      def count
        @lock.synchronize { @count }
      end
    end

    include Algebrick::TypeCheck
    extend Algebrick::TypeCheck

    def self.join(futures, result = Future.new)
      countdown = CountDownLatch.new(futures.size, result)
      futures.each do |future|
        Type! future, Future
        future.do_then { |_| countdown.countdown! }
      end
      result
    end

    def initialize(&task)
      @lock     = Mutex.new
      @value    = nil
      @resolved = false
      @failed   = false
      @waiting  = []
      @tasks    = []
      do_then &task if task
    end

    def value
      wait
      @lock.synchronize { @value }
    end

    def value!
      value.tap { raise value if failed? }
    end

    def resolve(result)
      set result, false
    end

    def fail(exception)
      Type! exception, Exception
      set exception, true
    end

    def evaluate_to(&block)
      set block.call, false
    rescue => error
      set error, true
    end

    def do_then(&task)
      call_task = @lock.synchronize do
        @tasks << task unless _ready?
        @resolved
      end
      task.call value if call_task
      self
    end

    def set(value, failed)
      @lock.synchronize do
        raise FutureAlreadySet, "future already set to #{@value} cannot use #{value}" if _ready?
        if failed
          @failed = true
        else
          @resolved = true
        end
        @value = value
        while (thread = @waiting.pop)
          begin
            thread.wakeup
          rescue ThreadError
            retry
          end
        end
        !failed
      end
      @tasks.each { |t| t.call value }
      self
    end

    def wait
      @lock.synchronize do
        unless _ready?
          @waiting << Thread.current
          @lock.sleep
        end
      end
      self
    end

    def ready?
      @lock.synchronize { _ready? }
    end

    def resolved?
      @lock.synchronize { @resolved }
    end

    def failed?
      @lock.synchronize { @failed }
    end

    def tangle(future)
      do_then { |v| future.set v, failed? }
    end

    private

    def _ready?
      @resolved || @failed
    end
  end

  class Reference
    include Algebrick::TypeCheck
    include Algebrick::Types

    attr_reader :core

    def initialize(core)
      @core = Type! core, Core
    end

    def actor
      core.actor
    end

    def path
      core.path
    end

    def tell(message)
      message message, nil
    end

    def ask(message, future = Future.new)
      message message, future
    end

    def message(message, future = nil)
      core.on_envelope Envelope[message,
                                future ? Some[Future][future] : None,
                                Actress.current ? Some[Reference][Actress.current] : None]
      return future || self
    end

    def to_s
      "#<#{self.class} #{path}>"
    end

    alias_method :inspect, :to_s

    def ==(other)
      Type? other, self.class and other.core == core
    end
  end

  Envelope = Algebrick.type do
    fields! message: Object,
            future:  Maybe[Future],
            sender:  Maybe[Reference]
  end

  module Envelope
    def sender_path
      sender.maybe { |reference| reference.path } || 'outside-actress'
    end
  end

  class MicroActor
    include Algebrick::TypeCheck
    include Algebrick::Matching

    Terminate = Algebrick.atom

    attr_reader :terminated

    def initialize(logger, *args)
      @logger      = logger
      @terminated  = Future.new
      @initialized = Future.new
      @thread      = Thread.new { run *args }
      Thread.pass until @mailbox
    end

    def <<(message)
      @mailbox << message
      self
    end

    private

    def run(*args)
      Thread.current.abort_on_exception = true

      @mailbox = Queue.new

      Thread.pass until @initialized && @terminated
      delayed_initialize(*args)
      @initialized.resolve true

      catch(Terminate) { loop { receive } }
    end

    def delayed_initialize
    end

    def receive
      message = @mailbox.pop
      if message == Terminate
        on_terminate
      else
        on_message message
      end
    rescue Exception => error
      @logger.fatal "#{error.message} (#{error.class})\n#{error.backtrace * "\n"}"
    end

    def on_terminate
      terminate!
    end

    def terminate!
      @terminated.resolve true
      throw Terminate
    end

    def on_message(message)
      raise NotImplementedError
    end
  end

  module ReservedThread
  end

  # TODO be able to create instances without real core to test without concurrency
  class Abstract
    include Algebrick::TypeCheck
    extend Algebrick::TypeCheck
    include Algebrick::Matching

    attr_reader :core

    def self.new(core, *args, &block)
      allocate.tap do |actress|
        actress.__send__ :pre_initialize, core
        actress.__send__ :initialize, *args, &block
      end
    end

    def on_message(message)
      raise NotImplementedError
    end

    def reference
      core.reference
    end

    def world
      core.world
    end

    def logger
      core.logger
    end

    def on_envelope(envelope)
      Type! envelope, Envelope
      with_envelope envelope do
        on_message envelope.message
      end
    end

    def spawn(actress_class, name, *args, &block)
      world.spawn(actress_class, name, *args, &block)
    end

    private

    def pre_initialize(core)
      @core = Type! core, Core
    end

    def envelope
      @envelope or raise 'called outside with_envelope'
    end

    def with_envelope(envelope)
      @envelope = envelope
      yield
    ensure
      @envelope = nil
    end
  end

  class Core
    include Algebrick::TypeCheck

    attr_reader :reference, :name, :world, :path, :logger

    def initialize(world, executor, parent, name, actress_class, *args, &block)
      @mailbox    = Array.new
      @processing = false
      @world      = Type! world, World
      @executor   = Type! executor, Executor
      @parent     = Type! parent, Reference, NilClass
      @name       = Type! name, String
      # Todo children
      @path       = @parent ? "#{@parent.path}.#{name}" : name
      @logger     = world.logging[path]
      @reference  = Reference.new self

      @actress_class = Child! actress_class, Abstract
      execute { @actress = actress_class.new self, *args, &block }
    end

    def on_envelope(envelope)
      execute do
        @mailbox.push envelope
        process?
      end
    end

    private

    def process?
      unless @mailbox.empty? || @receive_envelope_scheduled
        @receive_envelope_scheduled = true
        execute { receive_envelope }
      end
    end

    def receive_envelope
      envelope = @mailbox.shift
      logger.debug "received #{envelope.message} from #{envelope.sender_path}"

      result = @actress.on_envelope envelope
      envelope.future.maybe { |f| f.resolve result }
    rescue => error
      logger.error error
      envelope.future.maybe { |f| f.fail error }
    ensure
      @receive_envelope_scheduled = false
      process?
    end

    def execute(future = nil, &block)
      @executor.execute reference do
        with_current_actress do
          result = block.call
          future.resolve result if future
        end
      end
      future
    end

    def with_current_actress
      Thread.current[:__current_actress__] = reference
      yield
    ensure
      Thread.current[:__current_actress__] = nil
    end
  end

  def self.current
    Thread.current[:__current_actress__]
  end

  class World
    include Algebrick::TypeCheck

    attr_reader :logging, :logger, :pool_size, :root, :clock, :executor

    def initialize(options = {})
      @logging   = Type! options[:logging] || Logging.new, Logging
      @logger    = logging['world']
      @pool_size = Type! options[:pool_size] || 10, Integer
      @clock     = Clock.new logging['clock']
      #@executor  = SharedExecutor::Dispatcher.new(logging['executor'], logging, pool_size, @clock)
      @executor  = SharedExecutorOptimized::Dispatcher.new(logging['executor'], logging, pool_size, @clock)
      @root      = create_root
    end

    def spawn(actress_class, name, *args, &block)
      if actress_class < ReservedThread
        @executor << SharedExecutor::AddThread
      end
      Core.new(self, @executor, (Actress.current || root), name, actress_class,
               *args, &block).reference
    end

    def terminate
      @executor << MicroActor::Terminate
      @executor.terminated.wait
    end

    private

    def create_root
      Core.new(self, @executor, nil, '', Root).reference
    end
  end

  class Root < Abstract
    def on_message(message)
      raise 'root does not accepts any messages'
    end
  end

  class BlockActress < Abstract
    def initialize(&on_message)
      @on_message = on_message
    end

    def on_message(message)
      @on_message.call message
    end
  end

  module Executor
    def execute(actor, &work)
      raise NotImplementedError
    end

    def size
      raise NotImplementedError
    end
  end

  #class ThreadedExecutor
  #  include AbstractExecutor
  #
  #  def initialize(logging)
  #    @threads = {}
  #    @queues  = {}
  #    @logger  = Type!(logging, Logging)[self.class]
  #  end
  #
  #  def execute(actor, &work)
  #    Type! actor, Reference
  #    @queues[actor]  ||= queue = Queue.new
  #    @threads[actor] ||= Thread.new do
  #      Thread.abort_on_exception = true
  #      executing(queue)
  #    end
  #    @queues[actor] << work
  #    self
  #  end
  #
  #  def terminate(actor)
  #    @queues.delete actor
  #    @threads.delete(actor).terminate
  #    self
  #  end
  #
  #  def size
  #    @queues.size
  #  end
  #
  #  private
  #
  #  def executing(queue)
  #    loop { queue.pop.call }
  #      # TODO para this sometimes blows up on <NoMethodError> undefined method `pop' for nil:NilClass
  #  rescue => error
  #    @logger.fatal error
  #  end
  #end

  class WorkQueue
    def initialize
      @stash = Hash.new { |hash, key| hash[key] = [] }
    end

    def push(key, work)
      @stash[key].push work
    end

    def shift(key)
      @stash[key].shift.tap { @stash.delete(key) if @stash[key].empty? }
    end

    def present?(key)
      @stash.key?(key)
    end

    def empty?(key)
      !present?(key)
    end

    def each
      @stash.each do |key, works|
        yield key, works
      end
    end
  end

  module SharedExecutor
    Message = Algebrick.type do
      variants Work             = type { fields actor: Reference, work: Proc },
               Finished         = type { fields actor: Reference, result: Object, worker: MicroActor },
               AddThread        = atom,
               CheckThreadCount = atom
    end

    class Worker < MicroActor
      def delayed_initialize(executor)
        @dispatcher = Type! executor, MicroActor
      end

      def on_message(message)
        match message,
              Work.(~any, ~any) >-> actor, work do
                @dispatcher << Finished[actor, work.call, self]
              end
      end
    end

    class Dispatcher < MicroActor
      include Executor

      attr_reader :size

      def delayed_initialize(logging, size, clock)
        @base_size      = Type! size, Integer
        @size           = 0
        @scale_down     = 0
        @clock          = Type! clock, Clock
        @active_actors  = Set.new
        @waiting_actors = Set.new
        @work_queue     = WorkQueue.new
        @free_workers   = []
        @logging        = Type! logging, Logging
        @terminating    = false

        size.times { create_worker }

        recalculate_scale_down
      end

      def execute(actor, &work)
        self << Work[actor, work]
      end

      private

      def on_message(message)
        #invariant!
        match message,
              Finished.(~any, any, ~any) >-> actor, worker do
                return_worker(worker)
                @active_actors.delete actor
                @waiting_actors.add actor if @work_queue.present?(actor)

                assign_work
              end,
              Work.(~any, ~any) >-> actor, work do
                if @terminating
                  logger.warn "dropping work #{work} for #{actor} - terminating"
                else
                  @waiting_actors.add actor unless @active_actors.include? actor
                  @work_queue.push actor, work

                  assign_work
                end
              end,
              AddThread >-> { create_worker },
              CheckThreadCount >-> { recalculate_scale_down }
        #invariant!
      end

      def recalculate_scale_down
        thread_count = ObjectSpace.each_object(ReservedThread).count # TODO replace
        @scale_down  = thread_count - (@size - @base_size)
        @clock.ping self, Time.now + 10, CheckThreadCount
      end

      def return_worker(worker)
        if @scale_down > 0 || @terminating
          remove_worker worker
          try_terminate
        else
          @free_workers << worker
        end
      end

      def on_terminate
        @free_workers.each { |w| remove_worker w }
        @free_workers.clear
        @terminating = true
        try_terminate
      end

      def try_terminate
        terminate! if @size == 0 && @terminating
      end

      def remove_worker(worker)
        worker << Terminate
        @scale_down -= 1
        @size       -= 1
        @logger.info "scale down to #{@size}"
      end

      def create_worker
        name = format('%s-%3d', Worker, @size += 1)
        @free_workers << w = Worker.new(@logging[name], self)
        @logger.info "scale up to #{@size}"
      end

      def assign_work
        while worker_available? && !@waiting_actors.empty?
          @active_actors.add(actor = @waiting_actors.shift)
          @free_workers.pop << Work[actor, @work_queue.shift(actor)]
        end
      end

      def worker_available?
        not @free_workers.empty?
      end

      def invariant!
        unless (@active_actors & @waiting_actors).empty?
          raise
        end
        unless !worker_available? || @waiting_actors.empty?
          raise
        end
        @waiting_actors.each do |actor|
          unless @work_queue.present?(actor)
            raise
          end
        end
        @work_queue.each do |actor, works|
          unless @active_actors.include?(actor) || @waiting_actors.include?(actor)
            raise
          end
        end
      end
    end
  end

  class SharedExecutorOptimized
    AddThread        = SharedExecutor::AddThread
    CheckThreadCount = SharedExecutor::CheckThreadCount

    class Worker < MicroActor
      def initialize(logger, executor)
        @dispatcher = Type! executor, MicroActor
        super(logger)
      end

      def on_message(message)
        @dispatcher << [message[0], message[1].call, self]
      end
    end

    class Dispatcher < MicroActor
      include Executor

      attr_reader :size

      def delayed_initialize(logging, size, clock)
        @base_size      = Type! size, Integer
        @size           = 0
        @scale_down     = 0
        @clock          = Type! clock, Clock
        @active_actors  = Set.new
        @waiting_actors = Set.new
        @work_queue     = WorkQueue.new
        @free_workers   = []
        @logging        = Type! logging, Logging
        @terminating    = false

        size.times { create_worker }

        recalculate_scale_down
      end

      def execute(actor, &work)
        self << [actor, work]
      end

      private

      def on_message(message)
        if message.is_a? Array
          if message.size == 3
            actor, _, worker = message
            @free_workers << worker
            @active_actors.delete actor
            @waiting_actors.add actor if @work_queue.present?(actor)

            assign_work
          else
            actor, work = message
            @waiting_actors.add actor unless @active_actors.include? actor
            @work_queue.push actor, work

            assign_work
          end
        else
          create_worker if message == AddThread
          recalculate_scale_down if message == CheckThreadCount
        end
      end

      def recalculate_scale_down
        thread_count = ObjectSpace.each_object(ReservedThread).count # TODO replace
        @scale_down  = thread_count - (@size - @base_size)
        @clock.ping self, Time.now + 10, CheckThreadCount
      end

      def return_worker(worker)
        if @scale_down > 0 || @terminating
          remove_worker worker
          try_terminate
        else
          @free_workers << worker
        end
      end

      def on_terminate
        @free_workers.each { |w| remove_worker w }
        @free_workers.clear
        @terminating = true
        try_terminate
      end

      def try_terminate
        terminate! if @size == 0 && @terminating
      end

      def remove_worker(worker)
        worker << Terminate
        @scale_down -= 1
        @size       -= 1
        @logger.info "scale down to #{@size}"
      end

      def create_worker
        name = format('%s-%3d', Worker, @size += 1)
        @free_workers << w = Worker.new(@logging[name], self)
        @logger.info "scale up to #{@size}"
      end

      def assign_work
        while worker_available? && !@waiting_actors.empty?
          @active_actors.add(actor = @waiting_actors.shift)
          @free_workers.pop << [actor, @work_queue.shift(actor)]
        end
      end

      def worker_available?
        not @free_workers.empty?
      end
    end
  end

  require 'set'

  class Clock < MicroActor

    Tick  = Algebrick.atom
    Timer = Algebrick.type do
      fields! who:  Object,
              when: Time,
              what: Object
    end

    module Timer
      def self.[](*fields)
        super(*fields).tap { |v| Match! v.who, -> v { v.respond_to? :<< } }
      end

      include Comparable

      def <=>(other)
        Type! other, self.class
        self.when <=> other.when
      end
    end

    Pills = Algebrick.type do
      variants None = atom,
               Took = atom,
               Pill = type { fields Float }
    end

    def ping(who, time, with_what = nil)
      Type! time, Time, Float
      time = Time.now + time if time.is_a? Float
      self << Timer[who, time, with_what]
    end

    private

    def delayed_initialize
      @timers        = SortedSet.new
      @sleeping_pill = None
      @sleep_barrier = Mutex.new
      @sleeper       = Thread.new { sleeping }
      Thread.pass until @sleep_barrier.locked? || @sleeper.status == 'sleep'
    end

    def on_terminate
      @sleeper.kill
      super
    end

    def on_message(message)
      match message,
            Tick >-> do
              run_ready_timers
              sleep_to first_timer
            end,
            ~Timer >-> timer do
              @timers.add timer
              if @timers.size == 1
                sleep_to timer
              else
                wakeup if timer == first_timer
              end
            end
    end

    def run_ready_timers
      while first_timer && first_timer.when <= Time.now
        first_timer.who << first_timer.what
        @timers.delete(first_timer)
      end
    end

    def first_timer
      @timers.first
    end

    def wakeup
      while @sleep_barrier.synchronize { Pill === @sleeping_pill }
        Thread.pass
      end
      @sleep_barrier.synchronize do
        @sleeper.wakeup if Took === @sleeping_pill
      end
    end

    def sleep_to(timer)
      return unless timer
      sec = [timer.when - Time.now, 0.0].max
      @sleep_barrier.synchronize do
        @sleeping_pill = Pill[sec]
        @sleeper.wakeup
      end
    end

    def sleeping
      @sleep_barrier.synchronize do
        loop do
          @sleeping_pill = None
          @sleep_barrier.sleep
          pill           = @sleeping_pill
          @sleeping_pill = Took
          @sleep_barrier.sleep pill.value
          self << Tick
        end
      end
    end
  end

  class Logging
    class AbstractAdapter
      def log(level, name, message = nil, &block)
        raise NotImplementedError
      end

      [:debug, :info, :warn, :error, :fatal].each do |level|
        define_method level do |name, message = nil, &block|
          log level, name, message, &block
        end
      end
    end

    class StandardLogger < AbstractAdapter
      attr_reader :logger

      def initialize(logger = ::Logger.new($stdout), level = 0, formatter = self.method(:formatter).to_proc)
        @logger           = logger
        @logger.formatter = formatter
        @logger.level     = level
      end

      def log(level, name, message, &block)
        @logger.log level(level), message, name, &block
      end

      LEVELS = { debug: 0,
                 info:  1,
                 warn:  2,
                 error: 3,
                 fatal: 4 }

      def level(name)
        LEVELS[name]
      end

      def formatter(severity, datetime, name, msg)
        format "[%s] %5s %s: %s\n",
               datetime.strftime('%H:%M:%S.%L'),
               severity,
               #(name ? name + ' -- ' : ''),
               name,
               case msg
               when ::String
                 msg
               when ::Exception
                 "#{ msg.message } (#{ msg.class })\n" <<
                     (msg.backtrace || []).join("\n")
               else
                 msg.inspect
               end
      end
    end

    class NamedLogger
      attr_reader :logger_adapter, :name

      def initialize(logger_adapter, name)
        @logger_adapter = logger_adapter
        @name           = name.to_s
      end

      def log(level, message = nil, &block)
        @logger_adapter.log level, @name, message, &block
      end

      [:debug, :info, :warn, :error, :fatal].each do |level|
        define_method level do |message = nil, &block|
          log level, message, &block
        end
      end
    end

    attr_reader :logger_adapter

    def initialize(logger_adapter = StandardLogger.new)
      @logger_adapter        = logger_adapter
      @named_loggers         = {}
      @named_loggers_barrier = Mutex.new
    end

    def [](name)
      @named_loggers_barrier.synchronize do
        name                 = name.to_s
        @named_loggers[name] ||= NamedLogger.new(@logger_adapter, name)
      end
    end
  end

  #class MicroActorComplex
  #  include Algebrick::TypeCheck
  #  include Algebrick::Matching
  #
  #  attr_reader :logger, :initialized
  #
  #  Terminate = Algebrick.atom
  #
  #  def initialize(logger, *args)
  #    @logger      = logger
  #    @initialized = Future.new
  #    @thread      = Thread.new { run *args }
  #    Thread.pass until @mailbox
  #  end
  #
  #  def <<(message)
  #    raise 'actor terminated' if terminated?
  #    @mailbox << [message, nil]
  #    self
  #  end
  #
  #  def ask(message, future = Future.new)
  #    @mailbox << [message, future]
  #    future
  #  end
  #
  #  def stopped?
  #    @terminated.ready?
  #  end
  #
  #  private
  #
  #  def delayed_initialize(*args)
  #  end
  #
  #  def termination
  #    terminate!
  #  end
  #
  #  def terminating?
  #    @terminated
  #  end
  #
  #  def terminated?
  #    terminating? && @terminated.ready?
  #  end
  #
  #  def terminate!
  #    raise unless Thread.current == @thread
  #    @terminated.resolve true
  #  end
  #
  #  def on_message(message)
  #    raise NotImplementedError
  #  end
  #
  #  def receive
  #    message, future = @mailbox.pop
  #    #logger.debug "#{self.class} received:\n  #{message}"
  #    if message == Terminate
  #      if terminating?
  #        @terminated.do_then { future.resolve true } if future
  #      else
  #        @terminated = (future || Future.new).do_then { throw Terminate }
  #        termination
  #      end
  #    else
  #      result = on_message message
  #      future.resolve result if future
  #    end
  #  rescue => error
  #    logger.fatal error
  #  end
  #
  #  def run(*args)
  #    Thread.current.abort_on_exception = true
  #
  #    @mailbox    = Queue.new
  #    @terminated = nil
  #
  #    delayed_initialize(*args)
  #    Thread.pass until @initialized
  #    @initialized.resolve true
  #
  #    catch(Terminate) { loop { receive } }
  #  end
  #end

end

