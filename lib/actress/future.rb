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

module Actress
  class Future
    Error            = Class.new StandardError
    FutureAlreadySet = Class.new Error
    FutureFailed     = Class.new Error
    TimeOut          = Class.new Error

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

    def initialize(clock)
      @lock     = Mutex.new
      @clock    = Type! clock, Clock
      @value    = nil
      @resolved = false
      @failed   = false
      @waiting  = []
      @tasks    = []
      @timers   = []
    end

    def value(timeout = nil)
      wait timeout
      @lock.synchronize { @value }
    end

    def value!(timeout = nil)
      value(timeout).tap { raise value if failed? }
    end

    def resolve(result)
      set result, false
    end

    def fail(exception)
      Type! exception, Exception, String
      if exception.is_a? String
        exception = FutureFailed.new(exception).tap { |e| e.set_backtrace caller }
      end
      set exception, true
    end

    def evaluate_to(&block)
      resolve block.call
    rescue => error
      fail error
    end

    def evaluate_to!(&block)
      evaluate_to &block
      raise value if self.failed?
    end

    def do_then(&task)
      @lock.synchronize do
        @tasks << task unless _ready?
        @resolved
      end
      task.call self, value
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
        wakeup_threads
        expire_timers
      end
      @tasks.each { |t| t.call self, value }
      self
    end

    def wait(timeout = nil)
      @lock.synchronize do
        unless _ready?
          @waiting << Thread.current
          @timers << @clock.ping(self, timeout, Thread.current, :expired) if timeout
          @lock.sleep
          raise TimeOut unless _ready?
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

    # @api private
    def expired(thread)
      @lock.synchronize do
        thread.wakeup if @waiting.delete(thread)
      end
    end

    private

    def _ready?
      @resolved || @failed
    end

    def wakeup_threads
      while (thread = @waiting.pop)
        begin
          thread.wakeup
        rescue ThreadError
          retry
        end
      end
    end

    def expire_timers
      while (timer = @timers.pop)
        @clock.expire timer
      end
    end
  end
end
