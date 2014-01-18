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
  class ReservedManager
    include Algebrick::TypeCheck

    def initialize(executor, clock, interval = 1)
      @executor = executor
      @clock    = clock
      @reserved = []
      @interval = interval

      check
    end

    def reserve(reference)
      Type! reference, Reference
      @reserved << WeakRef.new(reference)
      @executor << SharedExecutor::AddThread
    end

    # @api private
    def check
      @reserved.delete_if do |weak_ref|
        if weak_ref.weakref_alive?
          false
        else
          @executor << SharedExecutor::RemoveThread
          true
        end
      end
      @clock.ping self, @interval, nil, :check
    end
  end
end
