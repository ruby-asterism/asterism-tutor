module Tutor
  # What goes to the LLM besides the bundle, and reading its answer.
  module Prompt
    TOOLS_RULES = File.read(File.expand_path("../../data/tools_ja.md", __dir__)).freeze
    # Put after the tool results of the last round of look-ups allowed.
    LOOKUP_DONE = "調べ物の上限に達した。これ以上は調べられない。ここまでの材料で、決まった形で答えて。".freeze
    # When the time left is short.
    LOOKUP_LATE = "時間が足りないので、これ以上は調べられない。ここまでの材料で、決まった形で答えて。".freeze

    module_function

    # The fixed text of every request (the same bytes for the same bundle).
    def system(bundle_text, tools:)
      tools ? "#{bundle_text}#{TOOLS_RULES}" : bundle_text
    end

    MODE_TEXT = {
      "ask" => "使い方: 質問。子どもの質問に答える。文書は変えない。<explain> だけを書く。",
      "hint" => "使い方: ヒント。文書のコードは変えず、考える手がかりを、コメントとして入れる行の組で返す。" \
                "<explain> と、1〜4 個の <hint line=\"N\"> を書く。" \
                "正しいコードや正しい名前をそのまま書かない (子どもが自分で気づけるように、どこを見るか・何と比べるか・" \
                "何を調べるかを書く)。<explain> も同じで、答えそのものは書かない。" \
                "エラーが付いていれば、エラーの原因に近い行にヒントを入れる。",
      "make" => "使い方: 作る。頼みのとおりのアプリを作り、文書の全体を <code> に書く。<explain> も書く。" \
                "今の文書があれば、それを元にしてよい。",
      "fix" => "使い方: 直してもらう。エラーと頼みに合わせて文書を直し、直した文書の全体を <code> に書く。" \
               "<explain> に、どこが違っていて、どう直したかを書く。直す必要の無い所は変えない。"
    }.freeze

    def numbered(doc)
      w = doc.lines.size.to_s.size
      doc.lines.each_with_index.map { |l, i| format("%#{w}d| %s", i + 1, l.chomp) }.join("\n")
    end

    # The user message of one request. req: the device's Hash; doc: the
    # document's text (nil when none was sent).
    def request(req, doc)
      mode = req["mode"]
      out = +"#{MODE_TEXT.fetch(mode)}\n"
      out << "答えの言葉: #{req['lang'] == 'en' ? 'English (simple words)' : '日本語'}\n\n"
      if doc && !doc.empty?
        out << "今の文書 (#{req['file'].to_s.empty? ? '無題' : req['file']}"
        out << "、カーソルは #{req['cy'].to_i + 1} 行目" if req["cy"].is_a?(Integer)
        out << "。行の頭の「数字|」は行番号で、文書の一部ではない):\n<doc>\n#{numbered(doc)}\n</doc>\n\n"
      elsif mode != "ask"
        out << "今の文書: 空 (まだ何も書いていない)\n\n"
      end
      err = req["error"].to_s
      out << "直前に実行したときのエラー:\n<error>\n#{err}\n</error>\n\n" unless err.empty?
      out << "子どもの文:\n<child>\n#{req['text']}\n</child>\n"
      out
    end

    # The message that asks for a fix after a check failed.
    def fix_request(mode, problems)
      list = problems.map { "- #{_1['line']} 行目: #{_1['message'] || _1['what']}#{_1['found'] ? " (#{_1['found']})" : ''}" }
      "検査で次の問題が見つかった。Family mruby の端末の Ruby で動くように直し、同じ形 (<explain> と " \
        "#{mode == 'hint' ? '<hint>' : '<code> に文書の全体'}) で答え直して。\n#{list.join("\n")}\n"
    end

    # {"explain" => text, "hints" => [{"line", "comment"}], "code" => text or nil}
    def parse(text)
      t = text.to_s
      explain = t[%r{<explain>(.*?)</explain>}m, 1]&.strip
      hints = t.scan(%r{<hint\s+line\s*=\s*"?(\d+)"?\s*>(.*?)</hint>}m).map { { "line" => _1.to_i, "comment" => _2.strip } }
      code = t[%r{<code>\n?(.*?)</code>}m, 1]
      if code
        code = code.sub(/\A\s*```[a-z]*\n/, "").sub(/\n```\s*\z/, "\n")
        code = "#{code.rstrip}\n"
      end
      explain = t.gsub(/<[^>]+>/, "").strip if explain.nil? && hints.empty? && code.nil?
      { "explain" => explain.to_s, "hints" => hints, "code" => code }
    end

    # A short form of a turn, kept for the next request (the talk).
    def talk_user(req, doc)
      s = +"(#{req['mode']}) #{req['text']}"
      s << " [文書 #{doc.lines.size} 行を付けた]" if doc && !doc.empty?
      s << " [エラーを付けた]" unless req["error"].to_s.empty?
      s
    end

    def talk_assistant(parsed, kind)
      s = +parsed["explain"].to_s
      s << "\n[ヒント #{parsed['hints'].size} 個を入れた]" if kind == "hint"
      s << "\n[文書の全体を返した]" if kind == "doc"
      s
    end
  end
end
