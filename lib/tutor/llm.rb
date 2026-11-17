module Tutor
  # The LLM behind one interface:
  #   complete(system:, messages:, meta:) -> {"text", "usage" => {"in", "out", "cache_write", "cache_read"}, "model", "stop"}
  # system is the bundle's text (cached by the provider when it can); messages
  # the talk and the request ([{role:, content:}]); meta what the fake needs
  # (mode, attempt). Errors are LLM::Error with a kind the device can show.
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

      def complete(system:, messages:, meta: {})
        params = {
          model: @cfg.dig("llm", "model").to_sym,
          max_tokens: @cfg.dig("llm", "max_tokens"),
          system_: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
          messages: messages
        }
        effort = @cfg.dig("llm", "effort").to_s
        params[:output_config] = { effort: effort.to_sym } unless effort.empty?
        msg = @client.messages.create(**params)
        text = msg.content.select { _1.type == :text }.map(&:text).join
        u = msg.usage
        {
          "text" => text,
          "usage" => { "in" => u.input_tokens.to_i, "out" => u.output_tokens.to_i,
                       "cache_write" => u.cache_creation_input_tokens.to_i, "cache_read" => u.cache_read_input_tokens.to_i },
          "model" => msg.model.to_s,
          "stop" => msg.stop_reason.to_s
        }
      rescue ::Anthropic::Errors::AuthenticationError, ::Anthropic::Errors::PermissionDeniedError => e
        raise Error.new("auth", "the LLM refused the key (#{e.class.name.split('::').last})")
      rescue ::Anthropic::Errors::RateLimitError
        raise Error.new("rate", "the LLM is busy (rate limit)")
      rescue ::Anthropic::Errors::APIConnectionError => e
        raise Error.new("network", "cannot reach the LLM (#{e.class.name.split('::').last})")
      rescue ::Anthropic::Errors::APIStatusError => e
        raise Error.new("api", "the LLM answered #{e.status}")
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
    class Fake
      attr_reader :calls

      def initialize
        @calls = 0
        @lock = Mutex.new
      end

      def complete(system:, messages:, meta: {})
        @lock.synchronize { @calls += 1 }
        last = messages.last[:content].to_s
        first_req = messages.reverse.find { _1[:role] == "user" && _1[:content].to_s.include?("<child>") }[:content].to_s
        child = first_req[%r{<child>\n(.*?)\n</child>}m, 1].to_s
        sleep 1.5 if child.include?("[[slow]]")
        if (secs = child[/\[\[wait (\d+)\]\]/, 1])
          sleep [secs.to_i, 120].min
        end
        history_turns = (messages.index { _1[:content].to_s.equal?(first_req) } || 0) / 2
        attempt = meta[:attempt].to_i
        text = answer(meta[:mode], child, first_req, attempt, history_turns, last)
        { "text" => text,
          "usage" => { "in" => LLM.estimate(last), "out" => LLM.estimate(text),
                       "cache_write" => attempt.zero? ? LLM.estimate(system) : 0, "cache_read" => attempt.zero? ? 0 : LLM.estimate(system) },
          "model" => "fake", "stop" => "end_turn" }
      end

      APP = <<~RUBY.freeze
        # AI: A small app that counts clicks.
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
            else APP
            end
          "<explain>#{talk} #{mode == 'fix' ? '直しました' : '作りました'} (#{attempt + 1} 回目)。</explain>\n<code>\n#{code}</code>"
        end
      end
    end
  end
end
