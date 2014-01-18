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
  class World
    include Algebrick::TypeCheck

    attr_reader :logging, :logger, :root, :clock

    def initialize(options = {})
      @logging          = Type! options[:logging] || Logging.new, Logging
      @logger           = logging['world']
      @pool_size        = Atomic.new 0
      @clock            = Clock.new logging['clock']
      @executor         = (options[:non_optimized] ? SharedExecutor::Dispatcher : SharedExecutorOptimized::Dispatcher).
          new(logging['executor'], logging, @clock, @pool_size,
              Type!(options[:pool_size] || 10, Integer))
      @reserved_manager = ReservedManager.new @executor, @clock
      @root             = create_root
    end

    def pool_size
      @pool_size.get
    end

    def spawn(actress_class, name, *args, &block)
      Core.new(self, @executor, (Actress.current || root), name, actress_class,
               *args, &block).reference
    end

    def terminate
      @executor << MicroActor::Terminate[terminate = Future.new]
      terminate.wait
    end

    def reserve_thread(reference)
      @reserved_manager.reserve reference
    end

    private

    def create_root
      Core.new(self, @executor, nil, '', Root).reference
    end
  end
end
