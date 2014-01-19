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

require 'hitimes'

module Actress
  class Clock < MicroActor
    include Algebrick::Types

    Tick   = Algebrick.atom
    Timer  = Algebrick.type do
      fields! who:   Object, # to ping back
              when:  Numeric, # to deliver
              what:  Maybe[Object], # to send
              where: Symbol # it should be delivered, which method
    end
    Remove = Algebrick.type { fields! timer: Timer }

    module Timer
      def self.[](*fields)
        super(*fields).tap { |v| Match! v.who, -> who { who.respond_to? v.where } }
      end

      include Comparable

      def <=>(other)
        Type! other, self.class
        self.when <=> other.when
      end

      def apply
        if Algebrick::Some[Object] === what
          who.send where, what.value
        else
          who.send where
        end
      end

      def time
        Time.at Time.now.to_f + self.when - Clock.run_time
      end
    end

    Pills = Algebrick.type do
      variants NoPill = atom,
               Took   = atom,
               Pill   = type { fields Float }
    end

    @run_time_interval ||= Hitimes::Interval.now
    def self.run_time
      @run_time_interval.to_f
    end

    def self.inherited(base)
      raise 'unsupported @run_time_interval is not delegated'
    end

    def ping(who, time, with_what = nil, where = :<<)
      Type! time, Numeric
      timer = Timer[who, run_time + time, with_what.nil? ? None : Some[Object][with_what], where]
      if terminated?
        Thread.new do
          sleep [timer.when - run_time, 0].max
          timer.apply
        end
      else
        self << timer
      end
      return timer
    end

    def expire(timer)
      if terminated?
        raise NotImplementedError
      else
        self << Remove[timer]
      end
    end

    private

    def run_time
      self.class.run_time
    end

    def initialize(logger)
      super logger, self
    end

    def delayed_initialize
      @timers        = SortedSet.new
      @sleep_barrier = Mutex.new
      @sleeper       = Thread.new { sleeping }
      Thread.pass until @sleep_barrier.synchronize { @sleeping_pill == NoPill }
    end

    def termination
      @sleeper.kill
      super
    end

    def on_message(message)
      match message,
            (on Tick do
              run_ready_timers
              sleep_to first_timer
            end),
            (on Remove.(~any) do |timer|
              @timers.delete timer
            end),
            (on ~Timer do |timer|
              @timers.add timer
              if @timers.size == 1
                sleep_to timer
              else
                wakeup if timer == first_timer
              end
            end)
    end

    def run_ready_timers
      while first_timer && first_timer.when <= run_time
        first_timer.apply
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
      sec = [timer.when - run_time, 0.0].max
      @sleep_barrier.synchronize do
        @sleeping_pill = Pill[sec]
        @sleeper.wakeup
      end
    end

    def sleeping
      @sleep_barrier.synchronize do
        loop do
          @sleeping_pill = NoPill
          @sleep_barrier.sleep
          pill           = @sleeping_pill
          @sleeping_pill = Took
          @sleep_barrier.sleep pill.value
          self << Tick
        end
      end
    end
  end
end
