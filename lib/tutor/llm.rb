module Tutor
  # The LLM behind one interface:
  #   complete(system:, messages:, meta:, tools: nil, tool_choice: nil, timeout: nil)
  #     -> {"text", "usage" => {"in", "out", "cache_write", "cache_read"}, "model", "stop",
  #         "content" => the answer's blocks as message content (to send back with tool results),
  #         "tool_calls" => [{"id", "name", "input"}]}
  # system is the bundle's text (cached by the provider when it can); messages
  # the talk and the request ([{role:, content:}]); meta what the fake needs
  # (mode, attempt); tools the tool definitions (Lookup.tools), tool_choice
  # "auto" or "none" (the tools stay defined, so the turns that used them
  # can be sent, but no new call is made); timeout seconds for this call.
  # Errors are LLM::Error with a kind the device can show.
  module LLM
    class Error < StandardError
      attr_reader :kind
      def initialize(kind, message)
        super(message)
        @kind = kind
      end
    end

    def self.make(cfg)
      case cfg.dig("llm", "provider")
      when "fake" then Fake.new
      when "anthropic" then Anthropic.new(cfg)
      else raise ArgumentError, "unknown llm provider #{cfg.dig('llm', 'provider').inspect}"
      end
    end

    def self.estimate(text) = (text.to_s.count("\x00-\x7f") / 4.0 + text.to_s.each_char.count { _1.ord > 127 }).round

    class Anthropic
      def initialize(cfg)
        require "anthropic"
        @cfg = cfg
        raise Error.new("config", "ANTHROPIC_API_KEY is not set") if ENV["ANTHROPIC_API_KEY"].to_s.empty?
        # No retries inside the SDK: every call is counted and logged by the gem.
        @client = ::Anthropic::Client.new(max_retries: 0, timeout: cfg.dig("llm", "timeout_s").to_f)
      end

      def complete(system:, messages:, meta: {}, tools: nil, tool_choice: nil, timeout: nil)
        params = {
          model: @cfg.dig("llm", "model").to_sym,
          max_tokens: @cfg.dig("llm", "max_tokens"),
          system_: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
          messages: messages
        }
        if tools
          params[:tools] = tools
          params[:tool_choice] = { type: (tool_choice || "auto").to_sym }
          # the turns of the look-ups are cached too, for the next round
          params[:cache_control] = { type: :ephemeral }
        end
        effort = @cfg.dig("llm", "effort").to_s
        params[:output_config] = { effort: effort.to_sym } unless effort.empty?
        opts = timeout ? { request_options: { timeout: timeout.to_f } } : {}
        msg = @client.messages.create(**params, **opts)
        text = msg.content.select { _1.type == :text }.map(&:text).join
        calls = msg.content.select { _1.type == :tool_use }.map { { "id" => _1.id, "name" => _1.name, "input" => _1.input } }
        u = msg.usage
        {
          "text" => text,
          "usage" => { "in" => u.input_tokens.to_i, "out" => u.output_tokens.to_i,
                       "cache_write" => u.cache_creation_input_tokens.to_i, "cache_read" => u.cache_read_input_tokens.to_i },
          "model" => msg.model.to_s,
          "stop" => msg.stop_reason.to_s,
          "content" => msg.content.filter_map { block_param(_1) },
          "tool_calls" => calls
        }
      rescue ::Anthropic::Errors::APITimeoutError
        raise Error.new("timeout", "the LLM did not answer in time")
      rescue ::Anthropic::Errors::AuthenticationError, ::Anthropic::Errors::PermissionDeniedError => e
        raise Error.new("auth", "the LLM refused the key (#{e.class.name.split('::').last})")
      rescue ::Anthropic::Errors::RateLimitError
        raise Error.new("rate", "the LLM is busy (rate limit)")
      rescue ::Anthropic::Errors::APIConnectionError => e
        raise Error.new("network", "cannot reach the LLM (#{e.class.name.split('::').last})")
      rescue ::Anthropic::Errors::APIStatusError => e
        raise Error.new("api", "the LLM answered #{e.status}")
      end

      # A block of the answer as it goes back in the next request.
      def block_param(b)
        case b.type
        when :text then { type: "text", text: b.text }
        when :tool_use then { type: "tool_use", id: b.id, name: b.name, input: b.input }
        when :thinking then { type: "thinking", thinking: b.thinking, signature: b.signature }
        when :redacted_thinking then { type: "redacted_thinking", data: b.data }
        end
      end
    end

    # A scripted LLM for the tests. It answers by mode, and markers in the
    # child's text pick the cases the tests need:
    #   [[regexp]]         make/fix: Regexp the first time, fixed when asked again
    #   [[regexp_always]]  make/fix: Regexp every time (the check never passes)
    #   [[syntax]]         make/fix: broken syntax the first time
    #   [[heredoc]]        hint: points into the heredoc of the document
    #   [[far]]            hint: points past the end of the document
    #   [[slow]]           waits 1.5 s first
    #   [[wait N]]         waits N seconds first (up to 120; for trying a
    #                      device by hand: edit, kill the app, stop the gem)
    #   [[noapp]]          make: code without a FmrbApp class every time
    # and, when the tools are offered (tool_choice "auto"):
    #   [[search TEXT]]    first round: search_source for TEXT
    #   [[read PATH]]      the round after the searches: read_source PATH
    #   [[lookup_loop]]    a search in every round it is allowed to
    # The answer after look-ups tells the first line of each tool result
    # ("(調べた: ...)"), so a test sees what came back.
    class Fake
      attr_reader :calls

      def initialize
        @calls = 0
        @lock = Mutex.new
      end

      def complete(system:, messages:, meta: {}, tools: nil, tool_choice: nil, timeout: nil)
        @lock.synchronize { @calls += 1 }
        last = messages.last[:content].to_s
        first_req = messages.reverse.find { _1[:role] == "user" && _1[:content].is_a?(String) && _1[:content].include?("<child>") }[:content].to_s
        child = first_req[%r{<child>\n(.*?)\n</child>}m, 1].to_s
        sleep 1.5 if child.include?("[[slow]]")
        if (secs = child[/\[\[wait (\d+)\]\]/, 1])
          sleep [secs.to_i, 120].min
        end
        history_turns = (messages.index { _1[:content].to_s.equal?(first_req) } || 0) / 2
        attempt = meta[:attempt].to_i
        start = messages.index { _1[:content].equal?(first_req) || _1[:content] == first_req } || 0
        results = messages[start..].select { _1[:role] == "user" && _1[:content].is_a?(Array) }
                                   .flat_map { |m| m[:content].select { _1[:type] == "tool_result" } }
        rounds = messages[start..].count { _1[:role] == "user" && _1[:content].is_a?(Array) }
        first = attempt.zero? && rounds.zero?
        usage = { "in" => LLM.estimate(last), "out" => 0,
                  "cache_write" => first ? LLM.estimate(system) : 0, "cache_read" => first ? 0 : LLM.estimate(system) }
        if tools && tool_choice.to_s != "none" && (calls = tool_calls(child, rounds))
          return { "text" => "", "usage" => usage.merge("out" => 20), "model" => "fake", "stop" => "tool_use",
                   "content" => calls.map { { type: "tool_use", id: _1["id"], name: _1["name"], input: _1["input"] } },
                   "tool_calls" => calls }
        end
        text = answer(meta[:mode], child, first_req, attempt, history_turns, last)
        unless results.empty?
          seen = results.map { _1[:content].to_s.lines.first.to_s.strip }
          text = text.sub("<explain>", "<explain>(調べた: #{seen.join(' / ')}) ")
        end
        { "text" => text, "usage" => usage.merge("out" => LLM.estimate(text)), "model" => "fake", "stop" => "end_turn",
          "content" => [{ type: "text", text: text }], "tool_calls" => [] }
      end

      # The tool calls the markers ask for in this round, or nil.
      def tool_calls(child, rounds)
        searches = child.scan(/\[\[search ([^\]]+)\]\]/).flatten
        reads = child.scan(/\[\[read ([^\]]+)\]\]/).flatten
        want =
          if child.include?("[[lookup_loop]]")
            [["search_source", { "pattern" => "loop #{rounds}" }]]
          elsif rounds.zero? && !searches.empty?
            searches.map { ["search_source", { "pattern" => _1 }] }
          elsif rounds == (searches.empty? ? 0 : 1) && !reads.empty?
            reads.map { ["read_source", { "path" => _1, "from" => 1, "to" => 5 }] }
          end
        return nil unless want
        want.each_with_index.map { |(n, input), i| { "id" => "toolu_fake_#{rounds}_#{i}", "name" => n, "input" => input } }
      end

      META = <<~RUBY.freeze
        #---fmrb
        # app_screen_name = "ClickApp"
        # default_window_mode = "window"
        # default_window_width = 160
        # default_window_height = 100
        #---
      RUBY

      APP = <<~RUBY.freeze
        #{META}# AI: A small app that counts clicks.
        class ClickApp < FmrbApp
          def on_create
            @clicks = 0
            draw_screen
          end

          def draw_screen
            clear_user_area
            # AI: Show the count at the top left.
            @gfx.draw_text(4, 4, "clicks: \#{@clicks}", theme_fg)
            @gfx.present
          end

          def on_event(ev)
            if ev[:type] == :mouse_up
              @clicks += 1
              draw_screen
            end
          end

          def on_update
            100
          end
        end
      RUBY

      REGEXP_APP = APP.sub("if ev[:type] == :mouse_up", "if ev[:type].to_s =~ /mouse_up/")
      SYNTAX_APP = APP.sub("    100\n  end\nend\n", "    100\n  end\n")
      NOAPP = "puts \"hello\"\n"
      # The app without the "#---fmrb" comment at its head ([[nometa]]: in
      # every answer; [[nometa_once]]: in the first one).
      NOMETA_APP = APP.delete_prefix(META)

      def answer(mode, child, req, attempt, turns, last)
        talk = "(会話の続き: #{turns} 往復)"
        case mode
        when "ask"
          "<explain>#{talk} これは偽物の AI の答えです。質問は「#{child.lines.first.to_s.strip}」でした。</explain>"
        when "hint"
          doc_lines = req[%r{<doc>\n(.*?)\n</doc>}m, 1].to_s.lines
          line =
            if child.include?("[[heredoc]]")
              (doc_lines.index { _1.include?("<<~") } || 0) + 2   # the first line inside the heredoc
            elsif child.include?("[[far]]")
              doc_lines.size + 50
            else
              cy = req[/カーソルは (\d+) 行目/, 1]
              cy ? cy.to_i : 1
            end
          "<explain>#{talk} ヒントを入れました。</explain>\n<hint line=\"#{line}\">ここで何をしたいかを考えてみよう。</hint>\n" \
            "<hint line=\"1\">最初の行です。</hint>"
        when "make", "fix"
          code =
            if child.include?("[[regexp_always]]") then REGEXP_APP
            elsif child.include?("[[regexp]]") && attempt.zero? then REGEXP_APP
            elsif child.include?("[[syntax]]") && attempt.zero? then SYNTAX_APP
            elsif child.include?("[[noapp]]") then NOAPP
            elsif child.include?("[[nometa]]") then NOMETA_APP
            elsif child.include?("[[nometa_once]]") && attempt.zero? then NOMETA_APP
            else APP
            end
          "<explain>#{talk} #{mode == 'fix' ? '直しました' : '作りました'} (#{attempt + 1} 回目)。</explain>\n<code>\n#{code}</code>"
        end
      end
    end
  end
end
