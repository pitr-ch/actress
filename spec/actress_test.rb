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
require 'minitest/reporters'
MiniTest::Reporters.use!

require 'pp'
require 'actress'
require 'timeout'

Thread.abort_on_exception = true

describe 'actress' do
  let(:world) do
    Actress::World.new logging: Actress::Logging.new(
                                    Actress::Logging::StandardLogger.new(
                                        Logger.new($stderr)))
  end

  after do
    world.terminate
  end

  it 'pings simple' do
    ping = world.spawn(Actress::BlockActress, 'ping') { |message| message }
    ping.ask(1).value!.must_equal 1
  end

  class ReservedBlockActress < Actress::BlockActress
    include Actress::ReservedThread
  end

  it 'reserved pings simple' do
    ping = world.spawn(ReservedBlockActress, 'ping') { |message| message }
    ping.ask(1).value!.must_equal 1
    world.executor.size.must_equal 11
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
    ping = world.spawn(Actress::BlockActress, 'ping') { |ref, i| ref.tell i }
    Array.new(100) do |pi|
      world.spawn(Pong, "pong-#{pi}", ping, 10, f = Actress::Future.new)
      f
    end.each &:value!

    GC.start
    GC.start

    actors_count = ObjectSpace.each_object(Actress::Abstract).count
    assert actors_count < 20, "it GCs the actors, it was #{actors_count}"
  end


end
