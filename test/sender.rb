# The test's stand-in for a device: calls <node>/tutor/helper the way the
# device's AI helper app will (report a0.md 2.2), from CRuby.
#
# As a library (the tests):
#   s = Sender.new(net)                       # finds */tutor/helper
#   r = s.run({"mode" => "ask", "text" => "..."}, doc: src)
#
# As a command (a manual run against a gem, e.g. with the real LLM):
#   ruby test/sender.rb --router tcp/127.0.0.1:17520 --node fmruby-test01 \
#     [--doc app.rb] [--error "..."] [--cy 3] [--out new.rb] MODE TEXT
# With a console's certificate (an mTLS router; the node is the
# certificate's name, the router its asterism.json's unless given):
#   ruby test/sender.rb --credentials fmruby-aaaaaa.tar [--router tls/localhost:17448] ask "..."
require "asterism"
require "json"

class Sender
  attr_reader :proxy, :path

  def initialize(net, path = nil, timeout: 5.0)
    @net = net
    @path = path || find
    @proxy = net[@path, timeout: timeout]
  end

  def find(wait = 5.0)
    t = Time.now
    loop do
      @net.poll unless @net.running?
      found = @net.each("*/tutor/helper")
      return found[0].asterism_path unless found.empty?
      raise "no */tutor/helper on the network" if Time.now - t > wait
      sleep 0.1
    end
  end

  def method_missing(name, *args) = @proxy.public_send(name, *args)
  def respond_to_missing?(*) = true

  def hello(info = { "fw" => "3.1.0", "lang" => "ja", "host" => "cruby" }) = @proxy.hello(info)

  # The document's part of a request: inline when it fits one piece, else in
  # pieces first (cut on line boundaries, like the device will).
  def send_doc(text, piece: 8192)
    return {} if text.nil?
    return { "doc_text" => text } if text.bytesize <= piece
    r = @proxy.doc_begin(text.bytesize)
    raise "doc_begin: #{r}" if r["error"]
    id = r["doc"]
    Sender.cut(text, piece).each_with_index do |p, i|
      a = @proxy.doc_piece(id, i, p)
      raise "doc_piece: #{a}" if a["error"]
    end
    { "doc" => id }
  end

  def self.cut(text, size)
    out = []
    cur = +""
    text.each_line do |l|
      if cur.bytesize + l.bytesize > size && !cur.empty?
        out << cur
        cur = +""
      end
      cur << l
    end
    out << cur unless cur.empty?
    out
  end

  # Polls status until the ticket ends; yields each new state.
  def wait(ticket, timeout: 60, every: 0.2)
    t = Time.now
    last = nil
    loop do
      s = @proxy.status(ticket)
      raise "status: #{s}" if s["error"]
      yield s if block_given? && s["state"] != last
      last = s["state"]
      return s if %w[done failed cancelled].include?(last)
      raise "ticket #{ticket} still #{last} after #{timeout} s" if Time.now - t > timeout
      sleep every
    end
  end

  # The result with the document put together from its pieces ("doc").
  def fetch(ticket)
    r = @proxy.result(ticket)
    return r if r["error"]
    if r["pieces"].to_i.positive?
      r = r.merge("doc" => (0...r["pieces"]).map { @proxy.result_piece(ticket, _1)["text"] }.join)
    end
    r
  end

  # ask -> wait -> result -> ack. Returns the result (with "ticket").
  def run(req, doc: nil, ack: true, &blk)
    a = @proxy.ask(req.merge(send_doc(doc)))
    return a if a["error"]
    tk = a["ticket"]
    wait(tk, &blk)
    r = fetch(tk).merge("ticket" => tk)
    @proxy.ack(tk) if ack
    r
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  o = { router: nil, node: nil, app: "ai_helper" }
  OptionParser.new do |p|
    p.on("--router L") { o[:router] = _1 }
    p.on("--node ID") { o[:node] = _1 }
    p.on("--credentials TAR", "a console's .tar (mTLS)") { o[:credentials] = _1 }
    p.on("--app NAME", "this application's name (default ai_helper, the device's)") { o[:app] = _1 }
    p.on("--path P", "the helper's path (default: found)") { o[:path] = _1 }
    p.on("--doc FILE") { o[:doc] = File.read(_1) }
    p.on("--error TEXT") { o[:error] = _1 }
    p.on("--cy N", Integer) { o[:cy] = _1 }
    p.on("--out FILE", "where the returned document goes") { o[:out] = _1 }
  end.parse!
  mode, text = ARGV
  abort("usage: sender.rb [options] MODE TEXT") unless mode
  args = { app: o[:app] }
  if o[:credentials]
    args[:credentials] = o[:credentials]
    args[:node] = o[:node] if o[:node]
  else
    o[:router] ||= "tcp/127.0.0.1:17520"
    args[:node] = o[:node] || "fmruby-test01"
  end
  Asterism.connect(o[:router], **args) do |net|
    s = Sender.new(net, o[:path])
    p s.hello
    req = { "mode" => mode, "text" => text.to_s, "fw" => "3.1.0", "lang" => "ja", "ver" => 1 }
    req["error"] = o[:error] if o[:error]
    req["cy"] = o[:cy] if o[:cy]
    t0 = Time.now
    r = s.run(req, doc: o[:doc]) { |st| warn format("%5.1fs %s %s", Time.now - t0, st["state"], st["message"]) }
    doc = r.delete("doc")
    puts JSON.pretty_generate(r)
    if doc
      if o[:out]
        File.write(o[:out], doc)
        warn "document: #{o[:out]} (#{doc.bytesize} bytes)"
      else
        puts "----- document -----", doc
      end
    end
  end
end
