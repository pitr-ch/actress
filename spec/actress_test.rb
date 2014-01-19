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

require 'minitest/autorun'
if ENV['RM_INFO']
  require 'minitest/reporters'
  MiniTest::Reporters.use!
end

require 'pp'
require 'actress'
require 'benchmark'
#require 'ruby-prof'

# ensure there are no unresolved Futures at the end or being GCed
future_tests =-> do
  future_creations  = {}
  non_ready_futures = {}

  MiniTest.after_run do
    futures = ObjectSpace.each_object(Actress::Future).select { |f| !f.ready? }
    if futures.empty?
      puts 'all futures ready'
    else
      raise "there are unready futures:\n" +
                futures.map { |f| "#{f}\n#{future_creations[f.object_id]}" }.join("\n")
    end
  end

  Actress::Future.singleton_class.send :define_method, :new do |*args, &block|
    super(*args, &block).tap do |f|
      future_creations[f.object_id]  = caller(3)
      non_ready_futures[f.object_id] = true
    end
  end

  set_method = Actress::Future.instance_method :set
  Actress::Future.send :define_method, :set do |*args|
    begin
      set_method.bind(self).call *args
    ensure
      non_ready_futures.delete self.object_id
    end
  end

  MiniTest.after_run do
    begin
      if non_ready_futures.empty?
        puts 'no GCed non_ready_futures'
      else
        unified = non_ready_futures.each_with_object({}) do |(id, _), h|
          backtrace_first    = future_creations[id][0]
          h[backtrace_first] ||= []
          h[backtrace_first] << id
        end
        raise("there were #{non_ready_futures.size} non_ready_futures:\n" +
                  unified.map do |backtrace, ids|
                    "--- #{ids.size}: #{ids}\n#{future_creations[ids.first].join("\n")}"
                  end.join("\n"))
      end
    rescue => e
      p e
    end
  end

  # time out all futures by default
  default_timeout = 4
  wait_method     = Actress::Future.instance_method(:wait)

  Actress::Future.class_eval do
    define_method :wait do |timeout = nil|
      wait_method.bind(self).call(timeout || default_timeout)
    end
  end

end.call


describe 'actress' do
  { optimized: false, non_optimized: true }.each do |name, non_optimized|
    describe name do


      let(:world) do
        Actress::World.new pool_size:     10,
                           non_optimized: non_optimized,
                           logging:       Actress::Logging.new(
                                              Actress::Logging::StandardLogger.new(
                                                  Logger.new($stderr), 2))
      end

      after do
        world.terminate
      end

      it 'pings simple' do
        ping = world.spawn(Actress::BlockActress, 'ping') { |message| message }
        ping.ask(1).value!.must_equal 1
      end

      it 'reserved pings simple' do
        start = world.pool_size
        ping  = world.spawn(Actress::BlockActress, 'ping') { |message| message }
        world.reserve_thread ping
        ping.ask(1).value!.must_equal 1
        world.pool_size.must_equal start + 1
      end

      class Pong < Actress::Abstract
        def initialize(ping, count, done)
          @ping  = ping
          @count = count
          @done  = done
          @ping.tell [self.reference, 0]
        end

        def on_message(num)
          if num < @count
            @ping.tell [self.reference, num+1]
          else
            @done.resolve true
          end
        end
      end

      it 'pings complex' do
        compute =-> do
          count_to = 10
          counts   = Array.new(10) { [0, world.future] }

          counters = Array.new(counters_size = 30) do |i|
            world.spawn(Actress::BlockActress, "counter#{i}") do |count, future|
              if count < count_to
                counters[(i+1)%counters_size].tell [count+1, future]
              else
                future.resolve count
              end
            end
          end

          counts.each_with_index do |count, i|
            counters[(i)%counters_size].tell count
          end

          counts.each do |count, future|
            assert future.value >= count_to
          end

          #ping = world.spawn(Actress::BlockActress, 'ping') { |ref, i| ref.tell i }
          #Array.new(100) do |pi|
          #  world.spawn(Pong, "pong-#{pi}", ping, 10, f = Actress::Future.new)
          #  f
          #end.each &:value!
        end

        profile = false
        result  = nil

        require 'ruby-prof' if profile

        Benchmark.bmbm(10) do |b|
          b.report('actress') do
            RubyProf.start if profile
            compute.call
            result = RubyProf.stop if profile
          end
        end

        unless RUBY_PLATFORM == 'java'
          GC.start
          GC.start
          GC.start
          GC.start

          actors_count = ObjectSpace.each_object(Actress::Abstract).count
          unless actors_count < 30
            p "it GCs the actors, it was #{actors_count}"
          end
        end

        if profile
          #printer = RubyProf::FlatPrinterWithLineNumbers.new(result)
          printer = RubyProf::FlatPrinter.new(result)
          #printer = RubyProf::GraphPrinter.new(result)
          File.open 'prof.txt', 'w' do |f|
            printer.print(f)
          end
          printer = RubyProf::GraphHtmlPrinter.new(result)
          File.open 'prof.html', 'w' do |f|
            printer.print(f)
          end
        end

      end

      class DoNothing < Actress::MicroActor
        private
        def on_message(m)
        end
      end

      it 'no nil' do
        100.times do
          a = DoNothing.new world.logging['nothing'], world.clock
          a << 'm'
          a << DoNothing::Terminate[f = world.future]
          f.wait
        end
      end

    end
  end

  clock_class = Actress::Clock

  describe clock_class do

    let(:clock) { clock_class.new Logger.new($stderr) }

    it 'refuses who without #<< method' do
      -> { clock.ping Object.new, 0.1, :pong }.must_raise TypeError
      clock.ping [], 0.1, :pong
    end


    it 'pongs' do
      q = Queue.new
      clock

      start = Time.now
      clock.ping q, 0.1, o = Object.new
      assert_equal o, q.pop
      finish = Time.now
      assert_in_delta 0.1, finish - start, 0.01
    end

    it 'pongs on expected times' do
      q = Queue.new
      clock
      start = Time.now

      timer = clock.ping q, 0.3, :a
      assert_in_delta (Time.now + 0.3).to_f, timer.time.to_f, 0.02
      clock.ping q, 0.1, :b
      clock.ping q, 0.2, :c

      assert_equal :b, q.pop
      assert_in_delta 0.1, Time.now - start, 0.02
      assert_equal :c, q.pop
      assert_in_delta 0.2, Time.now - start, 0.02
      assert_equal :a, q.pop
      assert_in_delta 0.3, Time.now - start, 0.02
    end

    it 'works under stress' do
      threads = Array.new(4) do
        Thread.new do
          q     = Queue.new
          times = 20
          times.times { |i| clock.ping q, rand, i }
          assert_equal (0...times).to_a, Array.new(times) { q.pop }.sort
        end
      end
      threads.each &:join
    end


  end


  #class A
  #  def initialize
  #    @a = 'something'
  #  end
  #  def read
  #    @a.size
  #  end
  #end
  #
  #it 'no nil2' do
  #  10000.times do
  #    a = A.new
  #    t = Thread.new do
  #      begin
  #        a.read
  #      rescue => e
  #        p e
  #      end
  #    end
  #    t.join
  #  end
  #end

end

