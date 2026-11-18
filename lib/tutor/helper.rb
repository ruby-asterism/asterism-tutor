module Tutor
  # The object a device calls: <node>/tutor/helper (report a0.md 2.2). Every
  # method gets the caller's node ID (caller: :from), answers at once (the
  # LLM runs on the workers) and returns a Hash; a refusal is a Hash with
  # "error" (and "message" for the child), never an exception.
  class Helper
    METHODS = { hello: 1, doc_begin: 1, doc_piece: 3, ask: 1, status: 1, result: 1, result_piece: 2,
                rebase: 2, cancel: 1, pending: 0, ack: 1, new_talk: 0 }.freeze
    MODES = %w[ask hint make fix].freeze

    def initialize(cfg, store:, log:, limits:, jobs:)
      @cfg = cfg
      @store = store
      @log = log
      @limits = limits
      @jobs = jobs
    end

    def piece_max = @cfg.dig("store", "piece").to_i
    def doc_max = @cfg.dig("store", "doc_max").to_i

    def not_allowed(from, what)
      @log.write(:refused, device: from, call: what)
      { "error" => "not_allowed", "message" => "この端末は、この AI を使えるように登録されていません。" }
    end

    def allowed?(from) = @cfg.device_allowed?(from.to_s)

    def str(v)
      v.is_a?(String) ? v.dup.force_encoding("UTF-8").scrub : nil
    end

    def hello(info, from:)
      return not_allowed(from, "hello") unless allowed?(from)
      info = info.is_a?(Hash) ? info : {}
      @log.write(:hello, device: from, info: info)
      { "ok" => true, "modes" => @cfg.modes, "piece" => piece_max, "doc_max" => doc_max,
        "used" => @limits.used(from), "max" => @limits.max, "name" => @cfg.dig("network", "name") }
    end

    def doc_begin(bytes, from:)
      return not_allowed(from, "doc_begin") unless allowed?(from)
      return { "error" => "bad_request", "message" => "bytes" } unless bytes.is_a?(Integer) && bytes >= 0
      return { "error" => "too_large", "message" => "文書が大きすぎます (#{doc_max} バイトまで)。" } if bytes > doc_max
      { "doc" => @store.new_doc(from, bytes) }
    end

    def doc_piece(doc, i, text, from:)
      return not_allowed(from, "doc_piece") unless allowed?(from)
      text = str(text)
      return { "error" => "bad_request", "message" => "piece" } unless doc.is_a?(String) && i.is_a?(Integer) && i >= 0 && text
      return { "error" => "too_large", "message" => "片は #{piece_max} バイトまで" } if text.bytesize > piece_max
      have = @store.put_piece(from, doc, i, text)
      have ? { "have" => have } : { "error" => "not_found", "message" => "no such document" }
    end

    def ask(req, from:)
      return not_allowed(from, "ask") unless allowed?(from)
      return bad("the request is not a Hash") unless req.is_a?(Hash)
      mode = req["mode"].to_s
      return bad("unknown mode #{mode}") unless MODES.include?(mode)
      unless @cfg.modes.include?(mode)
        @log.write(:refused, device: from, call: "ask", mode: mode, why: "mode_off")
        return { "error" => "mode_off", "message" => "この使い方は、親の設定で止められています。" }
      end
      text = str(req["text"]).to_s
      return bad("text is too long") if text.bytesize > @cfg.dig("store", "text_max").to_i
      return bad("text is empty") if text.strip.empty? && %w[ask make].include?(mode)
      doc, why = take_doc(req, from)
      return bad(why) if why
      return bad("#{mode} needs the document") if %w[hint fix].include?(mode) && doc.to_s.empty?
      error = str(req["error"]).to_s
      emax = @cfg.dig("store", "error_max").to_i
      error = "#{error.byteslice(0, emax).scrub('')}..." if error.bytesize > emax
      if @jobs.closing?
        @log.write(:refused, device: from, call: "ask", mode: mode, why: "stopping")
        return { "error" => "stopping", "message" => "AI の係が止まるところです。少し待ってからもう一度送ってください。" }
      end
      return { "error" => "busy", "message" => "前の頼みがまだ終わっていません。" } if @store.active?(from)
      if (refusal = @limits.refuse(from))
        @log.write(:refused, device: from, call: "ask", mode: mode, why: "limit")
        return refusal
      end
      clean = { "mode" => mode, "text" => text, "error" => error, "file" => str(req["file"]).to_s,
                "ver" => req["ver"].is_a?(Integer) ? req["ver"] : nil,
                "cy" => req["cy"].is_a?(Integer) ? req["cy"] : nil, "cx" => req["cx"].is_a?(Integer) ? req["cx"] : nil,
                "fw" => str(req["fw"]).to_s, "lang" => str(req["lang"]) || "ja" }
      @limits.count(from)
      id = @store.new_ticket(from, "req" => clean, "doc" => doc)
      @log.write(:ask, device: from, ticket: id, req: clean, doc_sent: doc)
      @jobs.push(id)
      { "ticket" => id }
    end

    def bad(why) = { "error" => "bad_request", "message" => why }

    # [text or nil, reason or nil]
    def take_doc(req, from)
      if req["doc"].is_a?(String) && !req["doc"].empty?
        @store.take_doc(from, req["doc"])
      elsif (t = str(req["doc_text"]))
        return [nil, "doc_text over #{piece_max} bytes: send it in pieces"] if t.bytesize > piece_max
        [t, nil]
      else
        [nil, nil]
      end
    end

    def status(ticket, from:)
      return not_allowed(from, "status") unless allowed?(from)
      t = @store.ticket_of(from, ticket)
      return { "error" => "not_found", "message" => "その番号の頼みはありません。" } unless t
      { "state" => t["state"], "message" => t["state"] == "failed" ? t["fail_message"] : t["message"] }
    end

    def result(ticket, from:)
      return not_allowed(from, "result") unless allowed?(from)
      t = @store.ticket_of(from, ticket)
      return { "error" => "not_found", "message" => "その番号の頼みはありません。" } unless t
      case t["state"]
      when "done" then t["result"]
      when "failed" then { "error" => t["error"], "message" => t["fail_message"], "state" => "failed" }
      when "cancelled" then { "error" => "cancelled", "message" => "やめました。", "state" => "cancelled" }
      else { "error" => "not_ready", "state" => t["state"], "message" => t["message"] }
      end
    end

    def result_piece(ticket, i, from:)
      return not_allowed(from, "result_piece") unless allowed?(from)
      t = @store.ticket_of(from, ticket)
      return { "error" => "not_found" } unless t && t["state"] == "done"
      ps = t["doc_pieces"] || []
      return { "error" => "not_found", "message" => "no piece #{i}" } unless i.is_a?(Integer) && i >= 0 && i < ps.size
      { "i" => i, "text" => ps[i] }
    end

    # doc: {"doc" => id from doc_begin} or {"doc_text" => text}, and "ver".
    def rebase(ticket, doc, from:)
      return not_allowed(from, "rebase") unless allowed?(from)
      t = @store.ticket_of(from, ticket)
      return { "error" => "not_found", "message" => "その番号の頼みはありません。" } unless t
      return bad("only a finished hint can be rebased") unless t["state"] == "done" && t["result"]["kind"] == "hint"
      return bad("doc is not a Hash") unless doc.is_a?(Hash)
      text, why = take_doc(doc, from)
      return bad(why || "no document") if why || text.nil?
      { "ticket" => @jobs.rebase(t, text, doc["ver"].is_a?(Integer) ? doc["ver"] : nil) }
    end

    def cancel(ticket, from:)
      return not_allowed(from, "cancel") unless allowed?(from)
      t = @store.ticket_of(from, ticket)
      return { "error" => "not_found" } unless t
      @store.update(ticket, "cancel" => true)
      @store.update(ticket, "state" => "cancelled", "message" => "やめました") if t["state"] == "queued"
      @log.write(:cancel, device: from, ticket: ticket)
      { "ok" => true }
    end

    def pending(from:)
      return not_allowed(from, "pending") unless allowed?(from)
      @store.pending(from)
    end

    def ack(ticket, from:)
      return not_allowed(from, "ack") unless allowed?(from)
      @store.ack(from, ticket) ? { "ok" => true } : { "error" => "not_found" }
    end

    def new_talk(from:)
      return not_allowed(from, "new_talk") unless allowed?(from)
      @store.forget_talk(from)
      @log.write(:new_talk, device: from)
      { "ok" => true }
    end
  end
end
