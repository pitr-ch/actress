# DONE finishing
# DONE wait for response
# DONE futures
# DONE supervision
# DONE remove reference and move methods to private
# DONE supervise shared workers, collect errors from threads
# DONE add wrapper for calling methods on objects
# DONE references
# DONE actor reference ensure 1-1 mapping
# DONE allow restart of actor by updating reference pointer
# DONE executor executes actor blocks in order one by one
# DONE all methods changing state of the actor are done through executor
# DONE message definition
# DONE mailbox as a class
# DONE move mailbox to Reference
# DONE add ThreadedExecutor
# DONE add SharedExecutor based on normal actors
# DONE supervise by parent by default
# DONE add on_error
# TODO garbage collectable actors
# TODO hooks only!: preStart, postStop, preRestart, postRestart
# TODO mailbox with stash
# TODO become syntax for complex behavior, store invalid messages, https://gist.github.com/viktorklang/797035

# TODO smarter message filtering
# TODO deadlock detection?
# TODO remote actors?


require 'thread'
require 'set'
require 'algebrick'
require 'logging'

class Set
  def shift
    return nil if empty?
    @hash.shift[0] # FIXME will this work on JRuby?
  end
end

module Actress
  class Error < StandardError
  end

  class UnknownMessage < Error
    def initialize(raw_message)
      super "unknown message #{raw_message.body} from #{raw_message.sender.core.path}"
    end
  end

  def self.logger
    @logger ||= Logging.logger[self].tap do |logger|
      logger.level     = :info
      logger.appenders = Logging.appenders.stdout
      logger.additive  = false
    end
  end
  logger

  def self.current
    Thread.current[:__current_actress__]
  end

  module IsActor
    def is_actor_ref!(object)
      raise ArgumentError, "#{object.inspect} must be actor reference" unless object.kind_of? AbstractReference
      object
    end
  end

  extend IsActor

  class Mailbox < Queue
  end

  class Future
    class FutureHappen < StandardError
    end

    def initialize
      @queue           = Queue.new
      @value           = nil
      @ready           = false
      @write_semaphore = Mutex.new
      @read_semaphore  = Mutex.new
    end

    def ready?
      @ready
    end

    def set(result)
      @write_semaphore.synchronize do
        raise FutureHappen, 'future already happen, cannot set again' if ready?
        @queue << result
        @ready = true
        self
      end
    end

    def value
      @read_semaphore.synchronize { @value ||= @queue.pop }
    end

    def wait
      value
      self
    end
  end

  Stopped    = Algebrick::Atom.new
  Started    = Algebrick::Atom.new
  Paused     = Algebrick::Atom.new
  Terminated = Algebrick::Atom.new
  State      = Algebrick::Variant.new Started, Paused, Stopped, Terminated

  module State
    def self.names
      variants.map { |v| v.name }
    end

    def name
      match self,
            Stopped >> 'stopped',
            Started >> 'started',
            Paused >> 'paused',
            Terminated >> 'terminated'
    end
  end

  class AbstractReference
    include Algebrick::TypeCheck
    private_class_method :new
    attr_reader :core

    def initialize(core)
      @core = is_matching! core, Core
    end

    def actor
      core.actor if core
    end

    def tell(message)
      message message, false
    end

    def ask(message)
      message message, true
    end

    def message(message, sync)
      future = (sync ? Future.new : Core::NoFuture)
      core.mailbox.push Core::Letter[message,
                                     future,
                                     Actress.current || Core::NoSender]
      core.notify_new_message if core

      return future || self
    end

    def to_s
      super.gsub(/>$/, " of #{core.path}>")
    end

    alias_method :inspect, :to_s

    def ==(other)
      other.kind_of? self.class and
          other.core == core
    end
  end

  class Reference < AbstractReference
    (State.names.map { |s| :"#{s}?" } + [:start, :stop, :pause, :resume]).each do |method|
      define_method method do |*args|
        core.public_send method, *args
      end
    end
  end

  class Core
    include Algebrick::TypeCheck
    extend Algebrick::DSL
    extend Algebrick::Matching
    include Algebrick::Matching

    attr_reader :reference, :current_message, :world, :parent, :name, :path, :state, :children, :monitors,
                :actor, :logger, :mailbox
    private :current_message

    NoFuture    = Algebrick::Atom.new
    MaybeFuture = Algebrick::Variant.new NoFuture, Future
    NoSender    = Algebrick::Atom.new
    Sender      = Algebrick::Variant.new NoSender, AbstractReference
    Letter      = Algebrick::Product.new message: Object, future: MaybeFuture, sender: Sender
    Failed      = Algebrick::Product.new actor: AbstractReference, message: Object, error: Exception
    StateUpdate = Algebrick::Product.new actor: AbstractReference, old: State, new: State

    Shared   = Algebrick::Atom.new
    Threaded = Algebrick::Atom.new
    Default  = Algebrick::Atom.new
    Type     = Algebrick::Variant.new Shared, Threaded, Default

    module Letter
      def sender_path
        match self[:sender],
              NoSender          => 'none',
              AbstractReference => -> { self[:sender].core.path }
      end
    end

    def self.new(world, options, &actor_initializer)
      super(world, options, &actor_initializer).reference
    end

    DEFAULT_OPTIONS = { type: Default, reference_class: AbstractReference }

    def initialize(world, options = {}, &actor_initializer)
      options = DEFAULT_OPTIONS.merge options

      @name            = is_matching! options[:name], String
      @world           = is_matching! world, World
      @executor        = match options[:type],
                               (Shared | Default) >>-> { world.shared_executor },
                               Threaded >>-> { world.threaded_executor }
      @mailbox         = Mailbox.new
      @actor           = nil
      @initializer     = actor_initializer
      @current_message = nil

      is_kind_of!(options[:reference_class], Class)
      options[:reference_class] <= AbstractReference or raise TypeError
      @reference     = options[:reference_class].send(:new, self)
      @message_count = 0

      # TODO use normal Reference
      @parent        = is_matching!(if options[:is_root]
                                      reference
                                    else
                                      Actress.current || world.user
                                    end, AbstractReference)

      @path      = if options[:is_root]
                     name
                   else
                     "#{parent.core.path}::#{name}"
                   end
      # TODO use actor.class instead of self.class
      @logger    = options[:logger] || Logging.logger["Actress::#{path}"]
      @children  = []

      # first state change is not notified
      @monitors  = []
      self.state = Stopped

      is_matching! options[:monitors], nil, Array
      options[:monitors].all? { |a| is_matching! a, AbstractReference } if options[:monitors]
      @monitors += options[:monitors] if options[:monitors]

      @parent.core.add_child reference
    end

    State.variants.each do |state|
      define_method :"#{state.name.downcase}?" do
        self.state == state
      end
    end

    def start
      execute :execute_start
    end

    def stop
      execute :execute_stop
    end

    def terminate
      execute :execute_terminate
    end

    def restart
      execute :execute_restart
    end

    def pause
      execute :execute_pause
    end

    def resume
      execute :execute_resume
    end

    def add_child(actor)
      is_matching! actor, AbstractReference
      execute :execute_add_child, [actor]
    end

    def add_monitor(actor)
      is_matching! actor, AbstractReference
      execute :execute_add_monitor, [actor]
    end

    def delete_monitor(actor)
      is_matching! actor, AbstractReference
      execute :execute_delete_monitor, [actor]
    end

    def notify_new_message
      execute :execute_notify_new_message
      reference
    end

    private

    def execute(method = nil, args = [], description = nil, future = Future.new, &block)
      @executor.execute reference do
        begin
          Thread.current[:__current_actress__] = reference

          result = if method
                     logger.debug "executing method #{method.inspect}, #{args}, #{block}, desc: #{description}"
                     self.send method, *args, &block
                   else
                     logger.debug "executing block #{block}, desc: #{description}"
                     block.call
                   end
          future.set result if future
        ensure
          Thread.current[:__current_actress__] = nil
        end
      end
      future
    end

    # methods called inside execute

    def execute_start
      if stopped?
        # FIXME it will go to FATAL error when initializer fails, catch it!
        @actor     = is_matching! @initializer.call(reference), AbstractActor
        self.state = Started
        execute_schedule_mailbox_check
        @actor.on_start
        true
      else
        false
      end
    end

    def execute_stop
      if started? || paused?
        @actor.on_stop
        @actor     = nil
        self.state = Stopped
        true
      else
        false
      end
    end

    def execute_terminate
      execute_stop and
          if stopped?
            self.state = Terminated
            @executor.terminate reference # FIXME it will kill thread under the actor, this will never return?
            true
          else
            false
          end
    end

    def execute_restart
      execute_stop and execute_start
    end

    def execute_pause
      if started?
        self.state = Paused
        @actor.on_pause
        true
      else
        false
      end
    end

    def execute_resume
      if paused?
        self.state = Started
        @actor.on_resume
        true
      else
        false
      end
    end

    def execute_add_monitor(actor)
      monitors << actor
    end

    def execute_delete_monitor(actor)
      monitors.delete actor
    end

    def execute_add_child(child)
      children << child
    end

    def execute_notify_new_message
      @message_count += 1
      execute_schedule_mailbox_check
    end

    def execute_schedule_mailbox_check
      if !@mailbox_check_scheduled && started? && waiting_messages?
        @mailbox_check_scheduled = true
        execute :execute_receive
      end
    end

    def execute_receive
      receive if started?
      @mailbox_check_scheduled = false
      execute_schedule_mailbox_check
    end

    def state=(state)
      old_state = @state
      @state    = is_matching! state, State
      logger.debug "state: #{old_state} -> #{state}"
      monitors.each { |m| m.tell StateUpdate[reference, old_state, state] }
    end

    def waiting_messages?
      @message_count > 0
    end

    def receive
      set_current_message do |raw_message|
        begin
          body, future, _ = *raw_message
          logger.debug "from '#{raw_message.sender_path}' received '#{body}'"
          result = match body,
                         Failed.case { @actor.on_error(*body) },
                         any.case { @actor.on_message(body) }

          future.set result if Future === future
        rescue => error
          logger.error error
          @parent.tell Failed[reference, body, error]
          execute_pause
        end
      end
      nil
    end

    def set_current_message
      message          = mailbox.pop
      @message_count   -= 1
      @current_message = message
      yield message
    ensure
      @current_message = nil
    end
  end

  class AbstractActor
    include Algebrick::TypeCheck
    include Algebrick::Matching

    attr_reader :core

    def initialize
      @core = is_matching! Actress.current.core, Core
    end

    def on_message(message)
      unrecognized
    end

    def on_error(actor, message, error)
      actor.core.restart
    end

    def reference
      core.reference
    end

    def world
      core.world
    end

    def on_start
    end

    def on_stop
      core.children.each { |ch| ch.core.terminate }
      # FIXME clean children
    end

    def on_pause
      core.children.each { |ch| ch.core.pause }
    end

    def on_resume
      core.children.each { |ch| ch.core.resume }
    end

    def unrecognized
      raise UnknownMessage.new(current_message)
    end

    private

    def current_message
      core.current_message
    end
  end

  class BlockActor < AbstractActor
    def initialize(&on_message)
      super(&nil)
      @on_message = on_message
    end

    def on_message(message)
      @on_message.call message
    end
  end

  class World # TODO make an actor
    class SystemActor < AbstractActor

      protected

      def unrecognized
        logger.error "from #{current_message.sender_path} unrecognized message #{current_message.body}"
        #puts "ERROR root received #{current_message.body.inspect} from #{current_message.sender}"
      end
    end

    class Root < SystemActor
      def initialize
        super
      end

      def on_start
        super
        @user   = world.run(name: 'user', type: Core::Threaded) { User.new }
        @system = world.run(name: 'system', type: Core::Threaded) { System.new }
      end

      def on_message(message)
        case message
        when :user
          @user
        when :system
          @system
        else
          unrecognized
        end
      end

      def on_error(actor, message, error)
        if actor == reference
          logger.error 'root has failed'
        else
          super
        end
      end

      def on_stop
        @user.core.stop.wait
        @system.core.stop.wait
        super
      end
    end

    class User < AbstractActor
    end

    class System < SystemActor
      def initialize
        super
        #@logger = world.run(name: 'logger') { Logger.new }
        @shared_executor = world.run(name:            'shared_executor',
                                     type:            Core::Threaded,
                                     reference_class: SharedExecutorReference) do
          SharedExecutor.new world.pool_size
        end
        # TODO dead letter mailbox
      end

      #GetLogger = Actor.define_message :reference

      def on_message(message)
        case message
          #when GetLogger
          #  @logger ||= world.run(reference: message.reference) { Logger.new }
          #  @logger.core
          #when :logger
          #  @logger
        when :shared_executor
          @shared_executor
        else
          unrecognized
        end
      end
    end

    #class Logger < SystemActor
    #  def initialize
    #    require 'logger'
    #    @logger = ::Logger.new($stdout)
    #  end
    #
    #  def on_message(message)
    #    @logger.send message[0], message[1]
    #  end
    #end

    module AbstractExecutor
      include Algebrick::TypeCheck

      def execute(actor, &work)
        raise NotImplementedError
      end

      def terminate(actor)
        raise NotImplementedError
      end

      def size
        raise NotImplementedError
      end
    end

    class ThreadedExecutor
      include AbstractExecutor

      def initialize
        @threads = {}
        @queues  = {}
        @logger  = Logging.logger[self.class]
      end

      def execute(actor, &work)
        is_matching! actor, AbstractReference
        @queues[actor]  ||= Queue.new
        @threads[actor] ||= Thread.new { executing(actor) }
        @queues[actor] << work
        self
      end

      def terminate(actor)
        @queues.delete actor
        @threads.delete(actor).terminate
        self
      end

      def size
        @queues.size
      end

      private

      def executing(actor)
        loop { @queues[actor].pop.call }
      rescue => error
        @logger.fatal error
      end
    end

    class SharedExecutorReference < AbstractReference
      def execute(actor, &work)
        tell SharedExecutor::NewWork[actor, work]
      end
    end

    class SharedExecutor < AbstractActor
      class WorkStash
        def initialize
          @stash = Hash.new { |hash, key| hash[key] = [] }
        end

        def push(actor, work)
          @stash[actor].push work
        end

        def pop(actor)
          @stash[actor].pop.tap { |work| @stash.delete(actor) if work.nil? }
        end

        def empty?(actor = nil)
          @stash.has_key?(actor)
        end

        def present?(actor)
          !empty?(actor)
        end
      end

      class Worker < AbstractActor
        def initialize(executor)
          super()
          @executor = is_kind_of! executor, AbstractReference
        end

        def on_message(message)
          match message,
                Work.(~any, ~any) --> actor, work do
                  @executor.tell Finished[actor, work.call, self.reference]
                end
        end
      end

      Work     = Algebrick::Product.new actor: AbstractReference, work: Proc
      Finished = Algebrick::Product.new actor: AbstractReference, result: Object, worker: AbstractReference
      NewWork  = Algebrick::Product.new actor: AbstractReference, work: Proc
      Message  = Algebrick::Variant.new Work, Finished, NewWork

      include AbstractExecutor

      def initialize(size)
        super()
        @size           = size
        @active_actors  = Set.new
        @waiting_actors = Set.new
        @work_stash     = WorkStash.new
        @free_workers   = Array.new(size) do |i|
          world.run(name: "worker#{i}", type: Core::Threaded) { Worker.new reference }
        end
      end

      def on_message(message)
        match message,
              Finished.(~any, _, ~any) --> actor, worker do
                @free_workers << worker
                @active_actors.delete actor
                @waiting_actors.add actor if @work_stash.present?(actor)

                assign_work
              end,
              NewWork.(~any, ~any) --> actor, work do
                @waiting_actors.add actor
                @work_stash.push actor, work

                assign_work
              end
      end

      private

      def assign_work
        if worker_available? && !@waiting_actors.empty?
          @active_actors.add(actor = @waiting_actors.shift)
          @free_workers.pop.tell Work[actor, @work_stash.pop(actor)]
        end
      end

      def worker_available?
        not @free_workers.empty?
      end
    end

    include Algebrick::TypeCheck

    attr_reader :pool_size, :threaded_executor, :shared_executor,
                :root, :user, :system

    def initialize(options = {})
      @pool_size         = is_matching! options[:pool_size], Integer
      @threaded_executor = ThreadedExecutor.new
      @root              = create_root
      root.core.start.wait
      @system          = root.ask(:system).value
      @user            = root.ask(:user).value
      @shared_executor = system.ask(:shared_executor).value
      #@logger             = Reference.new { |ref| system.ask(System::GetLogger.new(ref)) }
    end

    def create(options = {}, &actor_initializer)
      Core.new self, options, &actor_initializer
    end

    def run(options = {}, &actor_initializer)
      create(options, &actor_initializer).tap { |a| a.core.start }
    end

    def spawn(options = {}, &actor_initializer)
      create(options, &actor_initializer).tap { |a| a.core.start.wait }
    end

    def terminate
      root.core.terminate.wait
    end

    protected

    def create_root
      create(name: 'root', is_root: true, type: Core::Threaded) { Root.new }
    end
  end


#class Abstract
#  include IsActor
#
#  attr_reader :reference, :current_message
#  alias_method :ref, :reference
#  private :current_message
#
#  ActorMessage = Actor.define_message :body, :future
#
#  def self.new(*args, &block)
#    super(*args, &block).reference
#  end
#
#  def initialize(*args, &block)
#    actor_initialize(*args, &block)
#    reference.ask(InitializeInside.new).wait
#  end
#
#  def stopped?
#    @stopped_future.ready?
#  end
#
#  def stopping?
#    @stopping
#  end
#
#  def stop
#    reference.tell Stop.new
#    @stopping = true
#    reference
#  end
#
#  def supervise_by(actor_ref)
#    reference.tell Link.new(is_actor_ref!(actor_ref))
#  end
#
#  InitializeInside = Actor.define_message
#  Stop             = Actor.define_message
#  Link             = Actor.define_message :supervisor
#  Failed           = Actor.define_message :actor, :message, :error
#
#  def on_message(message)
#    raise NotImplementedError
#  end
#
#  def join
#    stop
#    @stopped_future.value
#    return reference
#  end
#
#  protected
#
#  def actor_initialize
#    @reference       = create_reference
#    #@behaviours = behaviors
#    #@behaviours.each { |b| b.actor = self }
#    @stopping        = false
#    @stopped_future  = Future.new
#    @supervisor      = nil
#    @current_message = nil
#  end
#
#  def initialize_inside
#  end
#
#  def receive_internal_message(message)
#    case message
#    when InitializeInside
#      initialize_inside
#    when Stop
#      set_as_stopped
#    when Link
#      @supervisor = message.supervisor
#    else
#      on_message message
#    end
#  end
#
#  def after_tell
#  end
#
#  def create_reference
#    Reference.send :new, self
#  end
#
#  #CALLBACKS = [:on_tell, :accept_message?, :on_message]
#
#  private
#
#  #def call_callback(name, *args) # TODO cache
#  #  @behaviours.each { |behavior| behavior.send name, *args }
#  #end
#
#
#  def receive
#    message_body = set_current_message reference.mailbox.pop do |message|
#      message_body, future = message.body, message.future
#      result               = receive_internal_message message_body
#      future.set result if future
#      puts "received #{message_body} in #{self}" if DEBUG
#      message_body
#    end
#    nil
#  rescue => error
#    @supervisor.tell Failed.new(self, message_body, error) if @supervisor
#    puts "#{error.message} (#{error.class})\n#{error.backtrace * "\n"}" if $DEBUG || !@supervisor
#    set_as_stopped
#  end
#
#  def set_current_message(message)
#    @current_message = message
#    yield message
#  ensure
#    @current_message = nil
#  end
#
#  def set_as_stopped
#    #@stopping = true
#    @stopped_future.set true
#  end
#end
#
#class Threaded < Abstract
#  def actor_initialize
#    super()
#    spawned = Future.new
#    @thread = Thread.new do
#      Thread.current[:__current_actress__] = reference
#      spawned.set true
#      receiving
#    end
#    def @thread.inspect
#      super.gsub '>', " #{self[:__current_actress__].actor.class}>"
#    end
#    spawned.wait
#  end
#
#  private
#
#  def receiving
#    loop do
#      break if stopped?
#      receive
#    end
#  end
#end

#class Shared2 < Abstract
#  attr_reader :world
#
#  def actor_initialize(world)
#    super()
#    @world      = world
#    @processing = false
#  end
#
#  def after_tell
#    raise if ASSERT && reference.mailbox.empty?
#    unless @processing
#      execute do
#        @processing = true
#        receive
#        @processing = false
#      end
#    end
#  end
#
#  private
#
#  def execute(&block)
#    world.executor.work do
#      Thread.current[:__current_actress__] = reference
#      block.call
#    end
#  end
#end

#class Shared < Abstract
#  class Worker < Threaded
#    def actor_initialize(executor)
#      super()
#      @executor = is_actor_ref! executor
#    end
#
#    def on_message(message)
#      case message
#      when Work
#        actor_ref = message.actor
#        kidnap_thread_to_actor(actor_ref) do
#          raise if ASSERT && actor_ref.mailbox.empty?
#          raise if ASSERT && actor_ref.actor.stopped?
#          actor_ref.actor.send :receive
#        end
#        @executor.tell Finished.new(actor_ref, reference)
#      else
#        raise 'wrong message'
#      end
#    end
#
#    private
#
#    def kidnap_thread_to_actor(actor)
#      raise if ASSERT && !actor.kind_of?(AbstractReference)
#      Thread.current[:__current_actress__] = actor
#      yield
#    ensure
#      Thread.current[:__current_actress__] = reference
#    end
#  end
#
#  class Executor < Threaded
#    attr_reader :worker_pool_size
#
#    def actor_initialize(worker_pool_size = 50)
#      super()
#      @worker_pool_size = worker_pool_size
#    end
#
#    def initialize_inside
#      @free_workers   = Array.new(worker_pool_size) { Worker.new reference }
#      @active_actors  = Set.new # actors being worked on
#      @waiting_actors = Set.new # actors with waiting messages
#      @free_workers.each do |worker|
#        worker.actor.supervise_by reference
#      end
#    end
#
#    def on_message(message)
#      raise if ASSERT && !(@active_actors & @waiting_actors).empty?
#      case message
#      when Ready
#        actor_ref = message.actor
#        unless @active_actors.include?(actor_ref)
#          @waiting_actors << actor_ref
#          raise if ASSERT && actor_ref.mailbox.empty?
#          try_assign_work
#        end
#
#      when Finished
#        actor_ref, worker = message.actor, message.worker
#        @free_workers << worker
#        @active_actors.delete actor_ref
#        case
#        when actor_ref.mailbox.empty?
#          # do nothing, forget the actor
#        when actor_ref.actor.stopped?
#          # do nothing, forget the actor
#        else
#          @waiting_actors << actor_ref
#        end
#        try_assign_work
#      when Failed
#        $stderr.puts "Woker failed #{message.actor} with error\n" +
#                         "#{message.error.message} (#{message.error.class})\n#{message.error.backtrace * "\n"}"
#        @free_workers << Worker.new(reference)
#      end
#    end
#
#    private
#
#    def try_assign_work
#      unless @free_workers.empty? || @waiting_actors.empty?
#        actor = @waiting_actors.shift
#        @active_actors.add actor
#        @free_workers.pop.tell Work.new(actor)
#      end
#    end
#  end
#
#  Ready    = Actor.define_message :actor
#  Work     = Actor.define_message :actor
#  Finished = Actor.define_message :actor, :worker
#
#  def self.executor
#    if superclass.respond_to? :executor
#      superclass.executor
#    else
#      @executor ||= Executor.new
#    end
#  end
#
#  protected
#
#  def after_tell
#    raise if ASSERT && reference.mailbox.empty?
#    self.class.executor.tell Ready.new(reference)
#  end
#end


#class WrapperReference < AbstractReference
#  class Proxy
#    def initialize(wrapper, sync)
#      @wrapper = wrapper
#      @sync    = sync
#    end
#
#    def method_missing(method, *args, &block)
#      if allowed_call? method
#        @wrapper.message Wrapper::CallMethod.new(method, args, block), @sync
#      else
#        super
#      end
#    end
#
#    def respond_to?(method_name, include_private = false)
#      allowed_call?(method_name) || super(method_name, include_private)
#    end
#
#    private
#
#    def allowed_call?(method_name)
#      @wrapper.actor.allowed_call? method_name, @sync
#    end
#  end
#
#  attr_reader :future, :tell
#
#  def initialize(actor)
#    super actor
#    @future = Proxy.new self, true
#    @tell   = Proxy.new self, false
#  end
#end
#
#module AllowedCallsHelper
#  class AllowedCallsDSL
#    def initialize(&block)
#      @async = Set.new
#      @sync  = Set.new
#      instance_eval &block
#    end
#
#    def async(*methods)
#      methods.each { |method| @async.add method }
#    end
#
#    def sync(*methods)
#      methods.each { |method| @sync.add method }
#    end
#
#    def both(*methods)
#      async *methods
#      sync *methods
#    end
#
#    def to_hash
#      all   = @async & @sync
#      async = @async - all
#      sync  = @sync - all
#      hash  = {}
#      all.each { |m| hash.update m => :both }
#      async.each { |m| hash.update m => :tell }
#      sync.each { |m| hash.update m => :ask }
#      hash
#    end
#  end
#
#  def allowed_calls(&block)
#    if block
#      @allowed_calls = AllowedCallsDSL.new(&block).to_hash
#    else
#      @allowed_calls || (superclass.allowed_calls if superclass.respond_to? :allowed_calls) ||
#          raise('define allowed_calls first')
#    end
#  end
#end
#
#
#module Wrapper
#  def self.included(base)
#    base.send :attr_reader, :base, :allowed_calls
#  end
#
#  CallMethod = Actor.define_message :method, :args, :block
#
#  def actor_initialize(allowed_calls = nil, &initializer)
#    super()
#    @initializer   = initializer
#    @base          = nil
#    @allowed_calls = allowed_calls
#  end
#
#  def initialize_inside
#    @base          = @initializer.call(reference)
#    @allowed_calls ||= (@base.allowed_calls if @base.respond_to? :allowed_calls) ||
#        (@base.class.allowed_calls if @base.class.respond_to? :allowed_calls)
#  end
#
#  def on_message(message)
#    case message
#    when CallMethod
#      unless allowed_call? message.method, current_message.future
#        raise "call #{message.method} #{current_message.future ? :ask : :tell } is not allowed"
#      end
#      base.public_send message.method, *message.args, &message.block
#      # FINd return exceptions and raise them in remote caller when waiting for result
#    else
#      raise "unknown message #{message}"
#    end
#  end
#
#  def create_reference
#    WrapperReference.send :new, self
#  end
#
#  def allowed_call?(method, sync)
#    case allowed_calls
#    when :all
#      true
#    when Array
#      allowed_calls.include? method
#    when Hash
#      return false unless (condition = allowed_calls[method])
#      case condition
#      when :both
#        true
#      when :tell
#        !sync
#      when :sync
#        sync
#      else
#        raise ArgumentError, "wrong condition #{condition}, only :all, :async, :sync are allowed"
#      end
#    else
#      raise ArgumentError, "allowed_calls #{allowed_calls.inspect}"
#    end
#  end
#end

#class ThreadedWrapper < Threaded
#  include Wrapper
#end
#
#class SharedWrapper < Shared
#  include Wrapper
#end

#module Simple
#  def actor_initialize(*args, &block)
#    super(*args)
#    @on_message_block = block
#  end
#
#  def on_message(message)
#    @on_message_block.call(message)
#  end
#end
#
#class SimpleThreaded < Threaded
#  include Simple
#end
#
#class SimpleShared < Shared
#  include Simple
#end

#class SimpleShared2 < Shared2
#  include Simple
#end


#class Behavior
#  attr_accessor :actor
#
#  def on_tell(message, response)
#  end
#
#  def accept_message?
#    false
#  end
#
#  def on_message
#    raise NotImplementedError
#  end
#
#  def receive_next_message?
#    true
#  end
#
#  def delegate
#    []
#  end
#end
#
#class Stoppable < Behavior
#  Stop = Actor.define_message
#
#  def initialize
#    @stopping       = false
#    @stopped_future = Future.new
#  end
#
#  def on_tell
#
#  end
#
#  def accept?(message)
#
#  end
#
#  def on_message(message)
#
#  end
#
#  def receive_next_message?
#
#  end
#
#  def delegate
#    [:stop]
#  end
#
#  def stopped?
#    @stopped_future.ready?
#  end
#
#  def stopping?
#    @stopping
#  end
#
#  def stop
#    actor.tell Stop.new
#    @stopping = true
#  end
#
#end


#class World
#  class MicroActor
#    def initialize
#      @mailbox = Queue.new
#      @thread  = Thread.new { loop { receive } }
#    end
#
#    def <<(message)
#      @mailbox << message
#    end
#
#    def receive
#      on_message @mailbox.pop
#    rescue => error
#      puts "#{error.message} (#{error.class})\n#{error.backtrace * "\n"}"
#    end
#
#    def on_message(message)
#      raise NotImplementedError
#    end
#  end
#
#  Work     = Struct.new(:actor, :work)
#  Finished = Struct.new(:actor, :result, :worker)
#  NewWork  = Struct.new(:actor, :work)
#
#  class Worker < MicroActor
#    def initialize(executor)
#      super()
#      @executor = executor
#    end
#
#    def on_message(message)
#      @executor << Finished.new(message.actor, message.work.call, self)
#    end
#  end
#
#  class Executor < MicroActor
#    class WorkStash
#      def initialize
#        @stash = Hash.new { |hash, key| hash[key] = [] }
#      end
#
#      def push(actor, work)
#        @stash[actor].push work
#      end
#
#      def pop(actor)
#        @stash[actor].pop.tap { |work| @stash.delete(actor) if work.nil? }
#      end
#
#      def empty?(actor = nil)
#        @stash.has_key?(actor)
#      end
#
#      def present?(actor)
#        !empty?(actor)
#      end
#    end
#
#    def initialize(pool_size)
#      super()
#      @active_actors  = Set.new
#      @waiting_actors = Set.new
#      @work_stash     = WorkStash.new
#      @free_workers   = Array.new(pool_size) { Worker.new self }
#    end
#
#    def on_message(message)
#      actor = message.actor
#      case message
#      when Finished
#        @free_workers << message.worker
#        @active_actors.delete actor
#        @waiting_actors.add actor if @work_stash.present?(actor)
#
#        assign_work
#      when NewWork
#        @waiting_actors.add actor
#        @work_stash.push actor, message.work
#
#        assign_work
#      end
#    end
#
#    def execute(actor, work)
#      self << NewWork.new(actor, work)
#    end
#
#    private
#
#    def assign_work
#      if worker_available? && !@waiting_actors.empty?
#        @active_actors.add(actor = @waiting_actors.shift)
#        @free_workers.pop << Work.new(actor, @work_stash.pop(actor))
#      end
#    end
#
#    def worker_available?
#      not @free_workers.empty?
#    end
#  end
#end
#
#  class Executor2
#    def initialize(pool_size)
#      @work_queue = Queue.new
#      @pool       = Array.new(pool_size) { Thread.new { loop { process_work } } }
#
#      @incoming_work = Queue.new
#      @processing    = Set.new
#      @router        = Thread.new { loop { route } }
#    end
#
#    def work(actor_ref, &block)
#      @incoming_work.push [actor_ref, block]
#    end
#
#    private
#
#    def route
#      @incoming_work
#    end
#
#    def process_work
#      @work_queue.pop.call
#    rescue => error
#      puts "#{error.message} (#{error.class})\n#{error.backtrace * "\n"}"
#    end
#  end
#
#end

end
