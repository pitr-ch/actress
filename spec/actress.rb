require 'minitest/autorun'
require 'turn/autorun'

require 'pp'
require 'actress'
require 'timeout'

Turn.config do |c|
  # use one of output formats:
  # :outline  - turn's original case/test outline mode [default]
  # :progress - indicates progress with progress bar
  # :dotted   - test/unit's traditional dot-progress mode
  # :pretty   - new pretty reporter
  # :marshal  - dump output as YAML (normal run mode only)
  # :cue      - interactive testing
  c.format  = :outline
  # turn on invoke/execute tracing, enable full backtrace
  #c.trace   = true
  # use humanized test names (works only with :outline format)
  c.natural = true
end

Thread.abort_on_exception = true

describe Set do
  it do
    set = Set.new
    set.add 1
    refute set.empty?
    assert set.shift == 1
  end
end


describe 'actress' do
  i_suck_and_my_tests_are_order_dependent!

  def timeout(timeout = 10, should_fail = false)
    ret = Timeout::timeout(timeout) do
      yield
    end
    flunk 'it should timout' if should_fail
    ret
  rescue Timeout::Error => error
    raise error unless should_fail
  end

  let(:world) { timeout { Actress::World.new pool_size: 10 } }

  describe Actress::Future do
    it 'waits for result' do
      timeout do
        future = Actress::Future.new
        Thread.new { sleep 0.01; future.set 1 }
        assert !future.ready?
        future.value.must_equal 1
        assert future.ready?
        future.value.must_equal 1
      end
    end
  end

  describe Actress::World::ThreadedExecutor do
    it 'executes' do
      timeout do
        executor = Actress::World::ThreadedExecutor.new
        future   = Actress::Future.new
        executor.execute(Actress::AbstractReference.allocate) { future.set 1 }
        future.value.must_equal 1
      end
    end
  end

  describe Actress::World::SharedExecutor do
    it 'executes' do
      timeout do
        executor = world.shared_executor
        future   = Actress::Future.new
        ref      = world.create name: 'test'
        executor.execute(ref) { future.set 1 }
        future.value.must_equal 1
      end
    end
  end

  describe Actress::Core do
    it 'waits for value' do
      timeout do
        ping = world.spawn(name: 'ping') { Actress::BlockActor.new { |v| v } }
        r2   = ping.ask(2)
        r1   = ping.ask(1)
        r1.value.must_equal 1
        r2.value.must_equal 2
      end
    end

    describe 'created' do
      let(:actor) { timeout { world.create(name: 'ping') { Actress::BlockActor.new { |v| v } } } }

      it 'is stopped' do
        actor.core.must_be :stopped?
      end

      it 'has parent user' do
        actor.core.parent.must_equal world.user
      end

      it 'is not processing messages' do
        timeout(0.1, true) do
          actor.ask(1).value.must_equal 1
        end
      end

      describe 'then started' do
        it 'receives waiting messages' do
          timeout do
            r2 = actor.ask(2)
            r1 = actor.ask(1)
            actor.core.start
            r1.value.must_equal 1
            r2.value.must_equal 2
          end
        end
      end
    end

    it 'waits for stop' do
      timeout do
        waiting = world.spawn(name: 'sleeper') { Actress::BlockActor.new { |t| sleep t } }
        start   = Time.now
        waiting.ask(0.1).wait
        waiting.core.stop.wait
        (Time.now-start).must_be :>, 0.09
      end
    end

    [:by_options, :set_later].each do |variant|
      it "sends notifications when state is changed (#{variant})" do
        timeout do
          changes = Queue.new
          monitor = world.spawn(name: 'monitor') { Actress::BlockActor.new { |m| changes << m } }
          options = { name: 'an_actor' }
          options.update monitors: [monitor] if variant == :by_options
          an_actor = world.spawn(options) { Actress::BlockActor.new {} }
          an_actor.core.add_monitor(monitor).wait if variant == :set_later

          an_actor.core.must_be :started?
          an_actor.core.monitors.must_include monitor

          an_actor.core.pause.wait
          an_actor.core.resume.wait
          an_actor.core.stop.wait

          changes.pop.tap do |s|
            s[:actor].must_equal an_actor
            s[:old].must_equal Actress::Stopped
            s[:new].must_equal Actress::Started
          end if variant == :by_options
          changes.pop.tap do |s|
            s[:actor].must_equal an_actor
            s[:old].must_equal Actress::Started
            s[:new].must_equal Actress::Paused
          end
          changes.pop.tap do |s|
            s[:actor].must_equal an_actor
            s[:old].must_equal Actress::Paused
            s[:new].must_equal Actress::Started
          end
          changes.pop.tap do |s|
            s[:actor].must_equal an_actor
            s[:old].must_equal Actress::Started
            s[:new].must_equal Actress::Stopped
          end
        end
      end
    end

    it 'is supervised by user and restarted' do
      timeout do
        changes = Queue.new
        monitor = world.spawn(name: 'monitor') { Actress::BlockActor.new { |m| changes << m } }
        bad     = world.spawn(name: 'bad', monitors: [monitor]) do
          Actress::BlockActor.new do |t|
            raise 'my bad'
          end
        end
        bad.tell 1

        bad.core.parent.must_equal world.user

        changes.pop.must_equal Actress::Core::StateUpdate[actor: bad, old: Actress::Stopped, new: Actress::Started]
        changes.pop.must_equal Actress::Core::StateUpdate[actor: bad, old: Actress::Started, new: Actress::Paused]
        changes.pop.must_equal Actress::Core::StateUpdate[actor: bad, old: Actress::Paused, new: Actress::Stopped]
        changes.pop.must_equal Actress::Core::StateUpdate[actor: bad, old: Actress::Stopped, new: Actress::Started]
      end
    end

    it 'has current actor set' do
      timeout do
        ping = world.spawn(name: 'ping') { Actress::BlockActor.new { |v| Actress.current } }
        ping.ask(1).value.must_equal ping
      end
    end
  end


  #actor_classes = [Actor::SimpleThreaded, Actor::SimpleShared, Actor::SimpleShared2]
  #actor_classes.each do |klass|
  #  describe klass do
  #    args = [(world if klass == Actor::SimpleShared2)].compact
  #    it 'waits for value' do
  #      timeout do
  #        ping = klass.new(*args) { |v| v }
  #        ping.ask(1).value.must_equal 1
  #      end
  #    end
  #
  #    it 'waits on #join' do
  #      timeout do
  #        waiting = klass.new(*args) { |t| sleep t }
  #        start   = Time.now
  #        waiting.tell 0.1
  #        waiting.join
  #        (Time.now-start).must_be :>, 0.09
  #      end
  #    end
  #
  #    it 'supervises' do
  #      timeout do
  #        bad        = klass.new(*args) do |m|
  #          raise 'my bad'
  #        end
  #        f          = Actor::Future.new
  #        supervisor = klass.new(*args) do |failed|
  #          f.set failed
  #        end
  #        bad.supervise_by supervisor
  #        bad.tell 1
  #
  #        failed = f.value
  #        failed.must_be_kind_of Actor::Abstract::Failed
  #        #failed.actor.must_equal bad
  #        failed.error.message.must_equal 'my bad'
  #        supervisor.join
  #      end
  #    end
  #
  #    it 'has current actor set' do
  #      ping = klass.new(*args) { |v| Actor.current }
  #      ping.ask(1).value.must_equal ping
  #    end
  #  end
  #end

  #actor_classes = [Actor::ThreadedWrapper, Actor::SharedWrapper]
  #actor_classes.each do |klass|
  #  describe klass do
  #    class Base
  #      extend Actor::AllowedCallsHelper
  #      allowed_calls { both :a_method, :b_method }
  #
  #      def a_method
  #        'result'
  #      end
  #
  #      def b_method(future)
  #        future.set 'result'
  #      end
  #
  #      def c_method
  #      end
  #    end
  #
  #    it 'wraps actor in Actor::WrapperReference' do
  #      timeout do
  #        wrapper = klass.new { Base.new }
  #        wrapper.must_be_kind_of Actor::WrapperReference
  #      end
  #    end
  #
  #    it 'returns future' do
  #      timeout do
  #        wrapper = klass.new { Base.new }
  #        wrapper.future.a_method.value.must_equal 'result'
  #      end
  #    end
  #
  #    it 'works async' do
  #      timeout do
  #        wrapper = klass.new { Base.new }
  #        future  = Actor::Future.new
  #        wrapper.tell.b_method(future).must_equal wrapper
  #        future.value.must_equal 'result'
  #      end
  #    end
  #
  #    it 'not allowed method is not defined' do
  #      timeout do
  #        wrapper = klass.new { Base.new }
  #        assert !wrapper.respond_to?(:c_method)
  #      end
  #    end
  #  end
  #end

  after do
    #Logging.show_configuration
    #timeout { world.terminate }
  end
end

#Actor.logger.level = :info
#require 'benchmark'
#
#actors_count = 100
#bounce_times = 100
#messages     = 1000
#Benchmark.bmbm(10) do |b|
#  #b.report("#{messages*bounce_times} rand") do
#  #  done   = Queue.new
#  #  actors = Array.new(actors_count) do |i|
#  #    Actor::SimpleShared.new do |count|
#  #      if count < bounce_times
#  #        actors[rand(actors_count)] << count + 1
#  #      else
#  #        done << true
#  #      end
#  #    end
#  #  end
#  #
#  #  messages.times { |i| actors[i] << 0 }
#  #  messages.times { |i| done.pop }
#  #end
#
#  b.report(messages*bounce_times) do
#    world  = Actor::World.new pool_size: 10
#    done   = Queue.new
#    actors = Array.new(actors_count) do |i|
#      world.run(name: i.to_s) do
#        Actor::BlockActor.new do |count|
#          if count < bounce_times
#            actors[(i+1) % actors_count].tell count + 1
#          else
#            done.push true
#          end
#        end
#      end
#    end
#
#    messages.times { |i| actors[i % actors_count].tell 0 }
#    messages.times { done.pop }
#  end
#end

