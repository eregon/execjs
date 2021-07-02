require "execjs/runtime"

module ExecJS
  class GraalJSRuntime < Runtime
    # TODO: the contexts should actually be isolated, e.g. with Truffle inner contexts
    class Context < Runtime::Context
      def initialize(runtime, source = "", options = {})
        @context = ::Truffle::Interop.new_inner_context
        ::Truffle::Interop.eval_in_inner_context(@context, 'js', 'delete this.console')

        source = encode(source)

        @source = source
        unless source.empty?
          translate do
            eval_in_context(source)
          end
        end
      end

      def exec(source, options = {})
        source = encode(source)
        source = "(function(){#{source}})()" if /\S/.match?(source)
        source = "#{@source};\n#{source}" unless @source.empty?

        translate do
          eval_in_context(source)
        end
      end

      def eval(source, options = {})
        source = encode(source)
        source = "(#{source})" if /\S/.match?(source)
        source = "#{@source};\n#{source}" unless @source.empty?

        translate do
          eval_in_context(source)
        end
      end

      def call(source, *args)
        source = encode(source)
        source = "(#{source})" if /\S/.match?(source)
        source = "#{@source};\n#{source}" unless @source.empty?

        translate do
          function = eval_in_context(source)
          function.call(*convert_ruby_to_js(args))
        end
      end

      private

      def translate
        begin
          convert_js_to_ruby yield
        rescue ::RuntimeError => e
          if e.message.start_with?('SyntaxError:')
            error_class = ExecJS::RuntimeError
          else
            error_class = ExecJS::ProgramError
          end

          backtrace = e.backtrace.map { |line| line.sub('(eval)', '(execjs)') }
          raise error_class, e.message, backtrace
        end
      end

      def convert_js_to_ruby(value)
        case value
        when true, false, Integer, Float
          value
        else
          if value.nil?
            nil
          elsif value.respond_to?(:call)
            nil
          elsif value.respond_to?(:to_str)
            value.to_str
          elsif value.respond_to?(:to_ary)
            value.to_ary.map do |e|
              if e.respond_to?(:call)
                nil
              else
                convert_js_to_ruby(e)
              end
            end
          elsif Truffle::Interop.has_members?(value)
            object = value
            h = {}
            Truffle::Interop.members(object).each do |member|
              if Truffle::Interop.member_readable?(object, member)
                v = Truffle::Interop.read_member(object, member)
                unless v.respond_to?(:call)
                  h[convert_js_to_ruby(member)] = convert_js_to_ruby(v)
                end
              end
            end
            h
          else
            raise TypeError, "Unknown how to convert to Ruby: #{value.inspect}"
          end
        end
      end

      def convert_ruby_to_js(value)
        case value
        when nil, true, false, Integer, Float, String
          value
        when Array
          value.map { |e| convert_ruby_to_js(e) }
        when Hash
          h = {}
          value.each_pair do |k,v|
            h[convert_ruby_to_js(k)] = convert_ruby_to_js(v)
          end
          Truffle::Interop.hash_keys_as_members(h)
        else
          raise TypeError, "Unknown how to convert to JS: #{value.inspect}"
        end
      end

      class_eval <<-'RUBY', "(execjs)", 1
        def eval_in_context(code); ::Truffle::Interop.eval_in_inner_context(@context, 'js', code); end
      RUBY
    end

    def name
      "Graal.js"
    end

    def available?
      RUBY_ENGINE == "truffleruby" and Truffle::Interop.languages.include? "js"
    end
  end
end
