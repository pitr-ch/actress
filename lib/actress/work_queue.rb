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
  class WorkQueue
    def initialize
      @stash = Hash.new { |hash, key| hash[key] = [] }
    end

    def push(key, work)
      @stash[key].push work
    end

    def shift(key)
      @stash[key].shift.tap { @stash.delete(key) if @stash[key].empty? }
    end

    def present?(key)
      @stash.key?(key)
    end

    def empty?(key)
      !present?(key)
    end

    def each
      @stash.each do |key, works|
        yield key, works
      end
    end
  end
end

