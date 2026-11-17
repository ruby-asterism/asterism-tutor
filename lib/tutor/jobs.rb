module Tutor
  # The work behind a ticket, on worker threads (never on Asterism's
  # receiving thread): the LLM, the checks, asking again when a check fails,
  # and the result the device fetches.
  class Jobs
    STATE_TEXT = {
      "thinking" => "考えています",
      "checking" => "検査しています",
      "done" => "できました",
      "failed" => "うまくいきませんでした",
      "cancelled" => "やめました"
    }.freeze
    EXPLAIN_MAX = 4096

    def initialize(cfg, store:, log:, limits:, bundles:, llm:)
      @cfg = cfg
      @store = store
      @log = log
      @limits = limits
      @bundles = bundles
      @llm = llm
      @queue = Queue.new
      @threads = Array.new(cfg.dig("jobs", "workers").to_i.clamp(1, 8)) do
        Thread.new do
          while (id = @queue.pop)
            run(id)
          end
        end
      end
    end

    def push(id) = @queue << id

    def stop
      @threads.size.times { @queue << nil }
      @threads.each { _1.join(5) }
    end

    def set(id, state, extra = {})
      @store.update(id, { "state" => state, "message" => STATE_TEXT[state] }.merge(extra))
    end

    def cancelled?(id) = @store.ticket(id)&.fetch("cancel")

    def run(id)
      t = @store.ticket(id)
      return unless t && t["state"] == "queued"
      return finish_cancel(t) if t["cancel"]
      work(t)
    rescue LLM::Error => e
      fail_ticket(t, e.kind == "auth" || e.kind == "config" ? "llm_setup" : "llm", llm_message(e), e.message)
    rescue StandardError => e
      fail_ticket(t, "internal", "親の PC の側でエラーが起きました。", "#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    end

    def llm_message(e)
      case e.kind
      when "rate" then "AI が混んでいます。少し待ってからもう一度聞いてください。"
      when "network" then "親の PC から AI につながりません。"
      when "auth", "config" then "親の PC の AI の設定に問題があります。親に知らせてください。"
      else "AI がうまく答えられませんでした。"
      end
    end

    def finish_cancel(t)
      set(t["id"], "cancelled")
      @log.write(:cancelled, device: t["device"], ticket: t["id"])
    end

    def fail_ticket(t, error, message, detail = nil, problems: nil)
      return unless t
      set(t["id"], "failed", "error" => error, "fail_message" => message, "problems" => problems)
      @log.write(:failed, device: t["device"], ticket: t["id"], error: error, message: message, detail: detail, problems: problems)
    end

    def work(t)
      id = t["id"]
      req = t["req"]
      mode = req["mode"]
      doc = t["doc"]
      bundle = @bundles.for(req["fw"])
      if bundle.fallback?
        @log.write(:bundle_fallback, device: t["device"], ticket: id, asked: bundle.asked, used: bundle.fw)
      end
      history = @store.talk(t["device"]).flat_map { [{ role: "user", content: _1 }, { role: "assistant", content: _2 }] }
      messages = history + [{ role: "user", content: Prompt.request(req, doc) }]
      retries = @cfg.dig("limits", "retries").to_i
      attempt = 0
      loop do
        return finish_cancel(t) if cancelled?(id)
        set(id, "thinking")
        res = @llm.complete(system: bundle.text, messages: messages, meta: { mode: mode, attempt: attempt })
        cost = @cfg.cost(res["usage"])
        @limits.add_cost(cost)
        @log.write(:llm, device: t["device"], ticket: id, attempt: attempt, model: res["model"], bundle: bundle.fw,
                         prompt: messages.last[:content], history_turns: history.size / 2,
                         answer: res["text"], stop: res["stop"], usage: res["usage"], cost_usd: cost.round(6))
        return finish_cancel(t) if cancelled?(id)
        set(id, "checking")
        parsed = Prompt.parse(res["text"])
        problems, outcome = evaluate(mode, parsed, doc, bundle)
        @log.write(:check, device: t["device"], ticket: id, attempt: attempt, ok: problems.empty?, problems: problems,
                           placed: outcome && outcome["placed"], left_out: outcome && outcome["left_out"])
        if problems.empty?
          finish(t, parsed, outcome, bundle)
          return
        end
        attempt += 1
        if attempt > retries
          lines = problems.first(3).map { "#{_1['line']} 行目: #{_1['message'] || _1['what']}" }
          fail_ticket(t, "check", "AI のコードが検査に通らなかったので、送りません (#{lines.join(' / ')})。", problems: problems)
          return
        end
        messages += [{ role: "assistant", content: res["text"] }, { role: "user", content: Prompt.fix_request(mode, problems) }]
      end
    end

    # [problems, outcome]. Problems make the LLM answer again.
    def evaluate(mode, parsed, doc, bundle)
      case mode
      when "ask"
        return [[{ "line" => 0, "message" => "<explain> が無い" }], nil] if parsed["explain"].empty?
        [[], nil]
      when "hint"
        if parsed["hints"].empty? && parsed["explain"].empty?
          return [[{ "line" => 0, "message" => "<explain> も <hint> も無い" }], nil]
        end
        out = Check.place_hints(doc, parsed["hints"])
        unless Check.same_code?(doc, out["doc"])
          # Never expected (each comment was checked); keep the code as it was.
          out = { "doc" => doc, "placed" => [], "left_out" => parsed["hints"].map { _1.merge("why" => "whole check") } }
        end
        [[], out]
      else
        code = parsed["code"]
        return [[{ "line" => 0, "message" => "<code> が無い" }], nil] if code.nil? || code.strip.empty?
        probs = []
        if code.bytesize > @cfg.dig("store", "doc_max").to_i
          probs << { "line" => 0, "message" => "文書が大きすぎる (#{code.bytesize} バイト)" }
        end
        probs += Check.syntax(code).map { _1.merge("message" => "構文の誤り: #{_1['message']}") }
        probs += Check.pico(code, bundle.checks).map { _1.merge("message" => "端末の Ruby に無い: #{_1['what']} (#{_1['found']})") }
        need_app = mode == "make" || (doc && Check.app_class?(doc))
        if probs.empty? && need_app && !Check.app_class?(code)
          probs << { "line" => 0, "message" => "FmrbApp を継承したクラスが無い" }
        end
        [probs, { "doc" => code }]
      end
    end

    def pieces(text)
      size = @cfg.dig("store", "piece").to_i
      out = []
      cur = +""
      text.each_line do |l|
        while l.bytesize > size # a line longer than a piece: cut it on a character boundary
          head = l.byteslice(0, size).scrub("")
          out << cur unless cur.empty?
          cur = +""
          out << head
          l = l.byteslice(head.bytesize..)
        end
        if cur.bytesize + l.bytesize > size
          out << cur
          cur = +""
        end
        cur << l
      end
      out << cur unless cur.empty?
      out
    end

    def cut(text, max)
      return text if text.bytesize <= max
      "#{text.byteslice(0, max - 3).scrub('')}..."
    end

    def finish(t, parsed, outcome, bundle)
      id = t["id"]
      mode = t["req"]["mode"]
      explain = parsed["explain"].dup
      result = { "base_ver" => t["req"]["ver"], "bundle" => bundle.fw }
      full_hints = nil
      case mode
      when "ask"
        result["kind"] = "answer"
      when "hint"
        result["kind"] = "hint"
        orig = t["doc"].lines
        full_hints = outcome["placed"].map do |h|
          at = h["at"]
          { "line" => at, "text" => orig[at - 1].to_s.chomp, "prev" => at > 1 ? orig[at - 2].to_s.chomp : nil,
            "comment" => h["comment"] }
        end
        result["hints"] = full_hints.map { [_1["line"], _1["text"], _1["comment"]] }
        unless outcome["left_out"].empty?
          explain << "\n\n入れられなかったヒント:\n" + outcome["left_out"].map { "- #{_1['line']} 行目: #{_1['comment']}" }.join("\n")
        end
        result["left_out"] = outcome["left_out"].size
      else
        result["kind"] = "doc"
      end
      text = outcome && outcome["doc"]
      ps = text ? pieces(text) : []
      if text
        result["doc_bytes"] = text.bytesize
        result["pieces"] = ps.size
      end
      result["explain"] = cut(explain, EXPLAIN_MAX)
      if cancelled?(id)
        finish_cancel(t)
        return
      end
      set(id, "done", "result" => result, "doc_pieces" => ps, "full_hints" => full_hints, "done_at" => Time.now)
      @store.add_turn(t["device"], Prompt.talk_user(t["req"], t["doc"]), Prompt.talk_assistant(parsed, result["kind"]))
      @log.write(:result, device: t["device"], ticket: id, result: result, doc: text)
    end

    # A hint result again on the document as it is now (report a0.md 4):
    # each hint goes above the line with the same text (the nearest to where
    # it was when several have it; a blank or an "end" line is matched with
    # the line above it too). No LLM. Returns the new ticket's id.
    def rebase(t, doc, ver)
      lines = doc.lines.map(&:chomp)
      hints = []
      left = []
      t["full_hints"].each do |h|
        common = h["text"].strip.empty? || h["text"].strip == "end"
        cands = lines.each_index.select do |i|
          lines[i].rstrip == h["text"].rstrip && (!common || h["prev"].nil? || (i.positive? && lines[i - 1].rstrip == h["prev"].rstrip))
        end
        if cands.empty?
          left << h
          next
        end
        dist = cands.map { ((_1 + 1) - h["line"]).abs }
        best = dist.min
        if dist.count(best) > 1
          left << h
          next
        end
        hints << { "line" => cands[dist.index(best)] + 1, "comment" => h["comment"] }
      end
      out = Check.place_hints(doc, hints)
      out = { "doc" => doc, "placed" => [], "left_out" => hints } unless Check.same_code?(doc, out["doc"])
      left_all = left.map { { "line" => _1["line"], "comment" => _1["comment"] } } + out["left_out"]
      full = out["placed"].map do |h|
        at = h["at"]
        { "line" => at, "text" => lines[at - 1].to_s, "prev" => at > 1 ? lines[at - 2] : nil, "comment" => h["comment"] }
      end
      old = t["result"]
      explain = old["explain"].to_s.sub(/\n\n入れられなかったヒント:.*\z/m, "")
      unless left_all.empty?
        explain += "\n\n書きかえたので入れなかったヒント:\n" + left_all.map { "- #{_1['comment']}" }.join("\n")
      end
      ps = pieces(out["doc"])
      result = { "kind" => "hint", "base_ver" => ver, "bundle" => old["bundle"],
                 "hints" => full.map { [_1["line"], _1["text"], _1["comment"]] }, "left_out" => left_all.size,
                 "doc_bytes" => out["doc"].bytesize, "pieces" => ps.size, "explain" => cut(explain, EXPLAIN_MAX) }
      nid = @store.new_ticket(t["device"], "req" => t["req"].merge("ver" => ver), "doc" => doc, "rebased_from" => t["id"])
      set(nid, "done", "result" => result, "doc_pieces" => ps, "full_hints" => full, "done_at" => Time.now)
      @store.ack(t["device"], t["id"])
      @log.write(:rebase, device: t["device"], ticket: nid, from: t["id"], doc_sent: doc, result: result, doc: out["doc"])
      nid
    end
  end
end
