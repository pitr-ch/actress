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
  # TODO be able to create instances without real core to test without concurrency
  class Abstract
    include Algebrick::TypeCheck
    extend Algebrick::TypeCheck
    include Algebrick::Matching

    attr_reader :core

    def self.new(core, *args, &block)
      allocate.tap do |actress|
        actress.__send__ :pre_initialize, core
        actress.__send__ :initialize, *args, &block
      end
    end

    def on_message(message)
      raise NotImplementedError
    end

    def reference
      core.reference
    end

    alias_method :ref, :reference

    def world
      core.world
    end

    def logger
      core.logger
    end

    def on_envelope(envelope)
      Type! envelope, Envelope
      with_envelope envelope do
        on_message envelope.message
      end
    end

    def spawn(actress_class, name, *args, &block)
      world.spawn(actress_class, name, *args, &block)
    end

    def reserve!
      world.reserve_thread self
    end

    private

    def pre_initialize(core)
      @core = Type! core, Core
    end

    def envelope
      @envelope or raise 'called outside with_envelope'
    end

    def with_envelope(envelope)
      @envelope = envelope
      yield
    ensure
      @envelope = nil
    end
  end
end
