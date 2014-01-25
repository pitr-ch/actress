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

require 'thread'
require 'set'
require 'logger'
require 'English'
require 'algebrick'
require 'weakref'
require 'atomic'
#require 'justified/standard_error'

# TODO report failures and restarts
# - it could be implemented with behaviours

#noinspection RubyConstantNamingConvention
module Actress
  include Algebrick::Types

  class Set < ::Set
    def shift
      return nil if empty?
      @hash.shift[0]
    end
  end

  require 'actress/future'
  require 'actress/count_down_latch'
  require 'actress/reference'
  require 'actress/envelope'
  require 'actress/micro_actor'
  require 'actress/abstract'
  require 'actress/core'
  require 'actress/reserved_manager'
  require 'actress/executor'
  require 'actress/logging'
  require 'actress/work_queue'
  require 'actress/shared_executor'
  require 'actress/shared_executor_optimized'
  require 'actress/clock'
  require 'actress/world'

  def self.current
    Thread.current[:__current_actress__]
  end

  class Root < Abstract
    def on_message(message)
      raise 'root does not accepts any messages'
    end
  end

  class BlockActress < Abstract
    def initialize(&on_message)
      @on_message = on_message
    end

    def on_message(message)
      @on_message.call message
    end
  end
end

