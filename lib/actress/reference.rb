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
  class Reference
    include Algebrick::TypeCheck
    include Algebrick::Types

    attr_reader :core

    def initialize(core)
      @core = Type! core, Core
    end

    def actor
      core.actor
    end

    def path
      core.path
    end

    def tell(message)
      message message, nil
    end

    def ask(message, future = Future.new(core.world.clock))
      message message, future
    end

    def message(message, future = nil)
      core.__on_envelope Envelope[message,
                                  future ? Some[Future][future] : None,
                                  Actress.current ? Some[Reference][Actress.current] : None]
      return future || self
    end

    def to_s
      "#<#{self.class} #{path}>"
    end

    alias_method :inspect, :to_s

    def ==(other)
      Type? other, self.class and other.core == core
    end
  end
end
