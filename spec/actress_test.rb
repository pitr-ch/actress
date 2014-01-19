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

Thread.abort_on_exception = true

describe 'actress' do
  let(:world) do
    Actress::World.new logging:   Actress::Logging.new(
                                      Actress::Logging::StandardLogger.new(
                                          Logger.new($stderr), 2)),
                       pool_size: 10
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

