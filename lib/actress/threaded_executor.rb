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
  class ThreadedExecutor
    include AbstractExecutor

    def initialize(logging)
      @threads = {}
      @queues  = {}
      @logger  = Type!(logging, Logging)[self.class]
    end

    def execute(actor, &work)
      Type! actor, Reference
      @queues[actor]  ||= queue = Queue.new
      @threads[actor] ||= Thread.new do
        Thread.abort_on_exception = true
        executing(queue)
      end
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

    def executing(queue)
      loop { queue.pop.call }
        # TODO para this sometimes blows up on <NoMethodError> undefined method `pop' for nil:NilClass
    rescue => error
      @logger.fatal error
    end
  end
end
