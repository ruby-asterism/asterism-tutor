#!/usr/bin/env ruby
# Makes the knowledge bundle of one firmware version from a family-mruby
# checkout (read only): bundles/<fw>/ and bundles/index.json.
#
#   ruby tools/make_bundle.rb --root /path/to/family-mruby [--out bundles] [--fw 3.1.0]
#
# What goes in (report a0.md 6.2):
#   rules_ja.md    the gem's own rules for talking with a child (data/rules_ja.md)
#   app_guide.md   the skill fmrb-app-new (without its "when done" part, which is about the sim)
#   api.rbs        sig/*.rbs: signature lines with a one-line English summary.
#                  Methods marked %a{fmrb.internal} stay: the mark means "not on
#                  the engine boundary" (a wrapper written in Ruby, such as
#                  draw_text, set_font, present), not "not for applications"
#   templates/*.rb the editor's templates (flash/lib/templates)
#   pitfalls.tsv   what the application VM lacks or does differently
#                  (asterism docs/ruby_features.md, column "app VM std", plus the skill's list)
#   checks.json    the same as patterns the gem's checker looks for (Prism nodes,
#                  constants, method names); only those the table marks ng / differs
#   samples/*.rb   a few small apps
#   manifest.json  where it was made from, the files, sizes and a token estimate
require "json"
require "fileutils"
require "optparse"

opts = { out: File.expand_path("../bundles", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR", "family-mruby checkout") { opts[:root] = File.expand_path(_1) }
  o.on("--out DIR", "bundles directory") { opts[:out] = File.expand_path(_1) }
  o.on("--fw VERSION", "firmware version (default: FMRB_OS_VERSION of fmrb.h)") { opts[:fw] = _1 }
end.parse!
root = opts[:root] or abort("--root is needed")
core = File.join(root, "fmruby-core")
asterism = File.join(root, "asterism")

def est_tokens(text)
  t = text.dup.force_encoding("UTF-8").scrub("")
  ascii = t.count("\x00-\x7f")
  (ascii / 4.0 + (t.length - ascii)).round
end

# The commit of a checkout, read from .git without running git.
def head_commit(dir)
  head = File.read(File.join(dir, ".git", "HEAD")).strip
  return head unless head.start_with?("ref: ")
  ref = head.sub("ref: ", "")
  loose = File.join(dir, ".git", ref)
  return File.read(loose).strip if File.exist?(loose)
  packed = File.join(dir, ".git", "packed-refs")
  line = File.exist?(packed) && File.readlines(packed).find { _1.end_with?(" #{ref}\n") }
  line ? line.split(" ").first : "unknown"
rescue Errno::ENOENT
  "unknown"
end

fw = opts[:fw] || File.read(File.join(core, "components/fmrb_common/include/fmrb.h"))[/FMRB_OS_VERSION\s+"([^"]+)"/, 1]
abort("cannot find FMRB_OS_VERSION") unless fw
dir = File.join(opts[:out], fw)
FileUtils.rm_rf(dir)
FileUtils.mkdir_p(File.join(dir, "templates"))
FileUtils.mkdir_p(File.join(dir, "samples"))

# 1. rules
FileUtils.cp(File.expand_path("../data/rules_ja.md", __dir__), File.join(dir, "rules_ja.md"))

# 2. app guide: the skill without its front matter and its last section
skill = File.read(File.join(root, ".claude/skills/fmrb-app-new/SKILL.md"))
skill = skill.sub(/\A---\n.*?\n---\n/m, "")
skill = skill.sub(/^## 書けたら\n.*\z/m, "")
File.write(File.join(dir, "app_guide.md"), skill.rstrip + "\n")

# 3. api.rbs (the compact form of report a0.md 6.1, English summaries)
api = +""
Dir[File.join(core, "sig/*.rbs")].sort.each do |f|
  api << "# #{File.basename(f)}\n"
  summary = nil
  first_doc = true
  File.readlines(f, chomp: true).each do |l|
    s = l.strip
    if s.start_with?("#")
      if first_doc && s.include?("<<en>>")
        summary = s.sub(/\A#\s*/, "").split("<<en>>", 2)[1].to_s.strip
        first_doc = false
      elsif first_doc && s.length > 1
        summary = s.sub(/\A#\s*/, "")
        first_doc = false
      end
      next
    end
    if s.empty?
      first_doc = true
      summary = nil
      next
    end
    if s.match?(/\A(def|attr_reader|attr_accessor|attr_writer)\b/)
      api << "  # #{summary}\n" if summary && !summary.empty?
      api << "  #{s}\n"
    elsif s.start_with?("%a{")
      next
    else
      api << "#{l}\n"
    end
    summary = nil
    first_doc = true
  end
end
File.write(File.join(dir, "api.rbs"), api)

# 4. templates
Dir[File.join(core, "flash/lib/templates/*.rb")].sort.each { FileUtils.cp(_1, File.join(dir, "templates")) }

# 5. pitfalls.tsv and checks.json
# What the checker can see for each probe of the feature table. A probe whose
# behaviour cannot be seen in the source (nil.to_i, deep recursion, ...) has
# no pattern: it is only told to the LLM through pitfalls.tsv.
PATTERNS = {
  "regexp_literal" => { nodes: %w[RegularExpressionNode InterpolatedRegularExpressionNode MatchLastLineNode
                                  InterpolatedMatchLastLineNode MatchWriteNode] },
  "regexp_class" => { consts: %w[Regexp MatchData] },
  "string_scan_regexp" => {},
  "module_name" => {},
  "struct" => { consts: %w[Struct] },
  "data_define" => { consts: %w[Data] },
  "set" => { consts: %w[Set] },
  "protected_method" => { calls0: %w[protected] },
  "method_object" => { calls0: %w[method] },
  "class_eval_string" => {},
  "instance_exec" => { calls: %w[instance_exec] },
  "kernel_proc" => { calls0: %w[proc] },
  "curry" => { calls: %w[curry] },
  "exception_cause" => {},
  "catch_throw" => { calls0: %w[catch throw] },
  "string_b" => {},
  "string_force_encoding" => { calls: %w[force_encoding encode] },
  "integer_bignum" => {},
  "rational" => { nodes: %w[RationalNode], consts: %w[Rational] },
  "complex" => { nodes: %w[ImaginaryNode], consts: %w[Complex] },
  "integer_digits" => { calls: %w[digits] },
  "integer_bit_length" => { calls: %w[bit_length] },
  "integer_clamp" => { calls: %w[clamp] },
  "hash_transform_values" => { calls: %w[transform_values transform_keys] },
  "hash_dig" => { calls: %w[dig] },
  "hash_compare_by_identity" => { calls: %w[compare_by_identity] },
  "hash_min_by" => { calls: %w[min_by max_by] },
  "array_each_slice" => { calls: %w[each_slice] },
  "array_each_cons" => { calls: %w[each_cons] },
  "array_tally" => { calls: %w[tally] },
  "array_filter_map" => { calls: %w[filter_map] },
  "array_sum" => { calls: %w[sum] },
  "array_minmax" => { calls: %w[minmax] },
  "array_zip" => { calls: %w[zip] },
  "array_flat_map" => { calls: %w[flat_map] },
  "array_group_by" => { calls: %w[group_by] },
  "array_sort_by" => { calls: %w[sort_by] },
  "array_cycle" => { calls: %w[cycle] },
  "range_step" => { calls_noblock: %w[step] },
  # No Enumerator on the device: the iterators without a block fail there
  # (each_with_index.map, times.map, ...).
  "enumerator_next" => { calls_noblock: %w[each each_with_index each_index map collect select reject times upto downto
                                           each_char each_byte each_line with_index each_with_object step] },
  "range_endless" => { endless_range: true },
  "enumerator_lazy" => { calls: %w[lazy] },
  "enumerator_new" => { consts: %w[Enumerator] },
  "fiber" => { consts: %w[Fiber] },
  "thread" => { consts: %w[Thread] },
  "mutex" => { consts: %w[Mutex] },
  "process_clock" => { consts: %w[Process] },
  "kernel_rand" => { consts: %w[Random] },
  "object_then" => { calls: %w[then yield_self] },
  "object_tap" => { calls: %w[tap] },
  "object_itself" => { calls: %w[itself] }
}.freeze

# From the skill's section on picoruby pitfalls (not in the feature table).
SKILL_ROWS = [
  ["skill_defined", "defined? is not there", "ng", { nodes: %w[DefinedNode] }],
  ["skill_binread", "File.binread is not there (File.open(path, \"rb\") and read)", "ng", { calls: %w[binread] }],
  ["skill_pack", "Array#pack is not there (\"\\x00\" * n with setbyte / getbyte)", "ng", { calls: %w[pack] }],
  ["skill_multi_index", "a[i], a[j] = a[j], a[i] (array elements on the left of a multiple assignment) breaks; use a temporary", "differs",
   { multi_index: true }],
  ["codegen_begin_end", "BEGIN {} / END {}, flip-flops and alias of globals do not compile", "ng",
   { nodes: %w[PreExecutionNode PostExecutionNode FlipFlopNode AliasGlobalVariableNode] }]
].freeze

feature_md = File.read(File.join(asterism, "docs/ruby_features.md"))
# The error each probe gave on the application VM (the list under the table):
# it tells what exactly is missing (kernel_rand: only the constant Random).
why = {}
feature_md.each_line do |l|
  next unless (m = l.match(/\A- `([^`]+)` on ([^:]*app VM std[^:]*): (.*)$/))
  why[m[1]] = m[3].sub("RubyProfile::Runner::", "").sub(" for RubyProfile::Runner", "").strip
end
rows = []
checks = []
feature_md.each_line do |l|
  cells = l.split("|").map(&:strip)
  next unless cells.size >= 11 && cells[1].start_with?("`")
  status = cells[9].delete("*")      # the "app VM std" column
  next unless %w[ng differs].include?(status)
  id = cells[1][/`([^`]+)`/, 1]
  desc = cells[1].sub(/`[^`]+`\s*/, "")
  rows << [id, desc, status, why[id].to_s]
  pat = PATTERNS[id]
  checks << { "id" => id, "what" => desc, "status" => status }.merge(pat.transform_keys(&:to_s)) if pat && !pat.empty?
end
SKILL_ROWS.each do |id, desc, status, pat|
  rows << [id, desc, status, ""]
  checks << { "id" => id, "what" => desc, "status" => status }.merge(pat.transform_keys(&:to_s))
end
File.write(File.join(dir, "pitfalls.tsv"),
           "# id\twhat\tapp VM (ng: missing or does not compile, differs: runs but gives another answer)\t" \
           "the error the probe gave (what exactly is missing)\n" +
           rows.map { _1.join("\t") }.join("\n") + "\n")
File.write(File.join(dir, "checks.json"), JSON.pretty_generate({ "fw" => fw, "checks" => checks }) + "\n")

# 6. samples
%w[flash/app/demo/pub_demo.app.rb flash/app/demo/sub_demo.app.rb flash/app/demo/piano.app.rb].each do |rel|
  FileUtils.cp(File.join(core, rel), File.join(dir, "samples"))
end

# manifest
files = Dir[File.join(dir, "**/*")].select { File.file?(_1) }.sort.map do |f|
  text = File.read(f)
  { "path" => f.delete_prefix(dir + "/"), "bytes" => text.bytesize, "tokens_est" => est_tokens(text) }
end
manifest = {
  "fw" => fw,
  "made_from" => { "core" => head_commit(core), "root" => head_commit(root), "asterism" => head_commit(asterism) },
  "made_at" => Time.now.utc.iso8601,
  "files" => files,
  "bytes" => files.sum { _1["bytes"] },
  "tokens_est" => files.sum { _1["tokens_est"] }
}
File.write(File.join(dir, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

# index.json: every bundle directory there
versions = Dir[File.join(opts[:out], "*/manifest.json")].map { File.basename(File.dirname(_1)) }
versions.sort_by! { Gem::Version.new(_1) }
File.write(File.join(opts[:out], "index.json"), JSON.pretty_generate({ "versions" => versions }) + "\n")

puts "bundle #{fw}: #{files.size} files, #{manifest['bytes']} bytes, ~#{manifest['tokens_est']} tokens (estimate)"
puts "  checks: #{checks.size}, pitfalls: #{rows.size}"
