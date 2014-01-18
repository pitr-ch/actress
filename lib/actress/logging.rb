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
  class Logging
    class AbstractAdapter
      def log(level, name, message = nil, &block)
        raise NotImplementedError
      end

      [:debug, :info, :warn, :error, :fatal].each do |level|
        define_method level do |name, message = nil, &block|
          log level, name, message, &block
        end
      end
    end

    class StandardLogger < AbstractAdapter
      attr_reader :logger

      def initialize(logger = ::Logger.new($stdout), level = 0, formatter = self.method(:formatter).to_proc)
        @logger           = logger
        @logger.formatter = formatter
        @logger.level     = level
      end

      def log(level, name, message, &block)
        @logger.log level(level), message, name, &block
      end

      LEVELS = { debug: 0,
                 info:  1,
                 warn:  2,
                 error: 3,
                 fatal: 4 }

      def level(name)
        LEVELS[name]
      end

      def formatter(severity, datetime, name, msg)
        format "[%s] %5s %s: %s\n",
               datetime.strftime('%H:%M:%S.%L'),
               severity,
               #(name ? name + ' -- ' : ''),
               name,
               case msg
               when ::String
                 msg
               when ::Exception
                 "#{ msg.message } (#{ msg.class })\n" <<
                     (msg.backtrace || []).join("\n")
               else
                 msg.inspect
               end
      end
    end

    class NamedLogger
      attr_reader :logger_adapter, :name

      def initialize(logger_adapter, name)
        @logger_adapter = logger_adapter
        @name           = name.to_s
      end

      def log(level, message = nil, &block)
        @logger_adapter.log level, @name, message, &block
      end

      [:debug, :info, :warn, :error, :fatal].each do |level|
        define_method level do |message = nil, &block|
          log level, message, &block
        end
      end
    end

    attr_reader :logger_adapter

    def initialize(logger_adapter = StandardLogger.new)
      @logger_adapter        = logger_adapter
      @named_loggers         = {}
      @named_loggers_barrier = Mutex.new
    end

    def [](name)
      @named_loggers_barrier.synchronize do
        name                 = name.to_s
        @named_loggers[name] ||= NamedLogger.new(@logger_adapter, name)
      end
    end
  end
end
