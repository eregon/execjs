require "execjs/runtime"

module ExecJS
  class GraalJSRuntime < Runtime
    class Context < Runtime::Context
      def initialize(runtime, source = "", options = {})
        @context = ::Truffle::Interop.new_inner_context

        source = encode(source)

        @source = source
        unless source.empty?
          eval_in_context(source)
        end
      end

      def exec(source, options = {})
        source = encode(source)
        source = "#{@source};\n#{source}" unless @source.empty?

        eval_in_context(source)
      end

      def eval(source, options = {})
        source = encode(source)

        # if /\S/ =~ source
        #   exec("return eval(#{::JSON.generate("(#{source})", quirks_mode: true)})")
        # end

        source = "(#{source})" if /\S/.match?(source)
        source = "return #{source}"
        source = "#{@source};\n#{source}" unless @source.empty?

        eval_in_context(source)
      end

      def call(source, *args)
        eval "#{source}.apply(this, #{::JSON.generate(args)})"
      end

      private

      def eval_in_context(code)
        code = <<-JS
          (function(program, execJS) { return execJS(program) })(function() { #{code}
          }, function(program) {
            try {
              delete this.console;
              var result = program();
              if (typeof result == 'undefined' && result !== null) {
                return '["ok"]';
              } else {
                try {
                  return JSON.stringify(['ok', result]);
                } catch (err) {
                  return JSON.stringify(['err', '' + err, err.stack]);
                }
              }
            } catch (err) {
              return JSON.stringify(['err', '' + err, err.stack]);
            }
          })
        JS

        begin
          result = ::Truffle::Interop.eval_in_inner_context(@context, 'js', code)
        rescue ::RuntimeError => e
          error_class = e.message.start_with?('SyntaxError:') ? ExecJS::RuntimeError : ExecJS::ProgramError
          line = e.message[/\(eval\):(\d+)/, 1] || 1
          backtrace = ["(execjs):#{line}"] + e.backtrace.map { |line| line.sub('(eval)', '(execjs)') }
          raise error_class, e.message, backtrace
        end

        extract_result(result.to_s)
      end

      def extract_result(output)
        raise if output.empty?
        status, value, stack = ::JSON.parse(output, create_additions: false)
        if status == "ok"
          value
        else
          stack ||= ""
          stack = stack.lines.map do |line|
            line.sub(" at ", "").sub('(eval)', '(execjs)').strip
          end
          stack.shift unless stack[0].to_s.include?("(execjs)")
          error_class = value =~ /SyntaxError:/ ? ExecJS::RuntimeError : ExecJS::ProgramError
          backtrace = stack + caller
          raise error_class, value, backtrace
        end
      end
    end

    def name
      "Graal.js"
    end

    def available?
      RUBY_ENGINE == "truffleruby" and Truffle::Interop.languages.include? "js"
    end
  end
end
