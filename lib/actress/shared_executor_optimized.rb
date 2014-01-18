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
  module SharedExecutorOptimized
    AddThread    = SharedExecutor::AddThread
    RemoveThread = SharedExecutor::RemoveThread

    class Worker < MicroActor
      def delayed_initialize(executor)
        @dispatcher = Type! executor, MicroActor
      end

      def on_message(message)
        @dispatcher << [message[0], message[1].call, self]
      end
    end

    class Dispatcher < MicroActor
      include Executor

      def delayed_initialize(logging, clock, pool_size, start_size)
        @size           = Type! pool_size, Atomic
        @scale_down     = 0
        @clock          = Type! clock, Clock
        @active_actors  = Set.new
        @waiting_actors = Set.new
        @work_queue     = WorkQueue.new
        @free_workers   = []
        @logging        = Type! logging, Logging
        @terminating    = false

        start_size.times { create_worker }
      end

      def execute(actor, &work)
        self << [actor, work]
      end

      private

      def on_message(message)
        if message.is_a? Array
          if message.size == 3
            actor, _, worker = message
            return_worker(worker)
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
          scale_down if message == RemoveThread
        end
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
        worker << Terminate[Future.new]
        @scale_down -= 1
        @size.update { |v| v - 1 }
        @logger.info "scale down to #{@size.get}"
      end

      def create_worker
        name = format('%s-%3d', Worker, @size.update { |v| v + 1 })
        @free_workers << w = Worker.new(@logging[name], self)
        @logger.info "scale up to #{@size.get}"
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
end
