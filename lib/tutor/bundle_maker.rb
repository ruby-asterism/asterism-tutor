require "json"
require "fileutils"
require "time"

module Tutor
  # Makes the knowledge bundle of one firmware version (a directory: the files
  # Bundle reads) from the sources, read only:
  #
  #   core      a checkout of fmruby-core (sig/, flash/lib/templates/, flash/app/demo/, fmrb.h)
  #   asterism  a checkout of asterism (docs/ruby_features.md: the table of pitfalls)
  #   app_guide the text of the skill fmrb-app-new (the family-mruby checkout's
  #             .claude/skills, which is not in the public repository; the
  #             gem keeps a copy in data/app_guide.md)
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
  #
  # The same sources give the same files byte for byte (the bundle's text is
  # the cached prefix of every request); only manifest.json has the time.
  module BundleMaker
    DATA = File.expand_path("../../data", __dir__)
    SAMPLES = %w[flash/app/demo/pub_demo.app.rb flash/app/demo/sub_demo.app.rb flash/app/demo/piano.app.rb].freeze
    VERSION_H = "components/fmrb_common/include/fmrb.h".freeze
    # The paths of fmruby-core the bundle reads (for a sparse checkout).
    CORE_PATHS = ["sig/", "flash/lib/templates/", "flash/app/demo/", VERSION_H].freeze
    ASTERISM_PATHS = ["docs/ruby_features.md"].freeze

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
      ["skill_multi_index", "a[i], a[j] = a[j], a[i] (array elements on the left of a multiple assignment) breaks; use a temporary",
       "differs", { multi_index: true }],
      ["codegen_begin_end", "BEGIN {} / END {}, flip-flops and alias of globals do not compile", "ng",
       { nodes: %w[PreExecutionNode PostExecutionNode FlipFlopNode AliasGlobalVariableNode] }]
    ].freeze

    module_function

    def est_tokens(text)
      t = text.dup.force_encoding("UTF-8").scrub("")
      ascii = t.count("\x00-\x7f")
      (ascii / 4.0 + (t.length - ascii)).round
    end

    # The firmware version the core checkout says (FMRB_OS_VERSION of fmrb.h).
    def core_version(core)
      File.read(File.join(core, VERSION_H))[/FMRB_OS_VERSION\s+"([^"]+)"/, 1]
    rescue SystemCallError
      nil
    end

    # The skill's text as the bundle's app guide: no front matter, no last section.
    def app_guide_from_skill(text)
      text.sub(/\A---\n.*?\n---\n/m, "").sub(/^## 書けたら\n.*\z/m, "").rstrip + "\n"
    end

    def app_guide_copy = File.read(File.join(DATA, "app_guide.md"))

    # Writes the bundle into out (made again from nothing). Returns the manifest.
    # made_from: {"core" => commit, ...} for the manifest.
    def make(core:, asterism:, out:, fw: nil, app_guide: nil, made_from: {}, clock: -> { Time.now })
      fw ||= core_version(core)
      raise ArgumentError, "cannot find FMRB_OS_VERSION in #{core}" unless fw
      FileUtils.rm_rf(out)
      FileUtils.mkdir_p(File.join(out, "templates"))
      FileUtils.mkdir_p(File.join(out, "samples"))

      FileUtils.cp(File.join(DATA, "rules_ja.md"), File.join(out, "rules_ja.md"))
      File.write(File.join(out, "app_guide.md"), app_guide || app_guide_copy)
      File.write(File.join(out, "api.rbs"), api_rbs(core))
      Dir[File.join(core, "flash/lib/templates/*.rb")].sort.each { FileUtils.cp(_1, File.join(out, "templates")) }

      rows, checks = pitfalls(File.read(File.join(asterism, "docs/ruby_features.md")))
      File.write(File.join(out, "pitfalls.tsv"),
                 "# id\twhat\tapp VM (ng: missing or does not compile, differs: runs but gives another answer)\t" \
                 "the error the probe gave (what exactly is missing)\n" +
                 rows.map { _1.join("\t") }.join("\n") + "\n")
      File.write(File.join(out, "checks.json"), JSON.pretty_generate({ "fw" => fw, "checks" => checks }) + "\n")

      SAMPLES.each do |rel|
        src = File.join(core, rel)
        FileUtils.cp(src, File.join(out, "samples")) if File.file?(src)
      end

      files = Dir[File.join(out, "**/*")].select { File.file?(_1) }.sort.map do |f|
        text = File.read(f)
        { "path" => f.delete_prefix("#{out}/"), "bytes" => text.bytesize, "tokens_est" => est_tokens(text) }
      end
      manifest = {
        "fw" => fw,
        "made_from" => made_from,
        "made_at" => clock.call.utc.iso8601,
        "files" => files,
        "bytes" => files.sum { _1["bytes"] },
        "tokens_est" => files.sum { _1["tokens_est"] },
        "checks" => checks.size,
        "pitfalls" => rows.size
      }
      File.write(File.join(out, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      manifest
    end

    # sig/*.rbs in the compact form of report a0.md 6.1 (English summaries).
    def api_rbs(core)
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
      api
    end

    # [rows of pitfalls.tsv, checks of checks.json] from asterism's feature table.
    def pitfalls(feature_md)
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
        status = cells[9].delete("*") # the "app VM std" column
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
      [rows, checks]
    end
  end
end
