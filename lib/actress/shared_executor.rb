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
  module SharedExecutor
    Message = Algebrick.type do
      variants Work         = type { fields actor: Core, args: Array },
               Finished     = type { fields actor: Core, result: Object, worker: MicroActor },
               AddThread    = atom,
               RemoveThread = atom
    end

    class Worker < MicroActor
      def delayed_initialize(executor)
        @dispatcher = Type! executor, MicroActor
      end

      def on_message(message)
        match message,
              Work.(~any, ~any) >-> actor, args do
                @dispatcher << Finished[actor, actor.__execute(*args), self]
              end
      end
    end

    class Dispatcher < MicroActor
      include Executor

      def delayed_initialize(logging, pool_size, start_size)
        @size           = Type! pool_size, Atomic
        @scale_down     = 0
        @active_actors  = Set.new
        @waiting_actors = Set.new
        @work_queue     = WorkQueue.new
        @free_workers   = []
        @logging        = Type! logging, Logging
        @terminating    = false

        start_size.times { create_worker }
      end

      def execute(actor, *args)
        self << Work[actor, args]
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
              RemoveThread >-> { scale_down }
        #invariant!
      end

      def scale_down
        @scale_down += 1 if @size.get > @scale_down
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
        terminate! if @size.get == 0 && @terminating
      end

      def remove_worker(worker)
        worker << Terminate[Future.new(@clock)]
        @scale_down -= 1
        @size.update { |v| v - 1 }
        @logger.info "scale down to #{@size.get}"
      end

      def create_worker
        name = format('%s-%3d', Worker, @size.update { |v| v + 1 })
        @free_workers << w = Worker.new(@logging[name], @clock, self)
        @logger.info "scale up to #{@size.get}"
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
end
