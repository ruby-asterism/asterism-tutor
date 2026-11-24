require "fileutils"
require "open3"

# Local git repositories that stand for fmruby-core and asterism (the tests
# never go to GitHub): a tag 3.0.0, then develop moves on (draw_picture
# comes in after the tag). Each test gets its own copy.
module SourcesFixture
  module_function

  def git(dir, *args)
    out, st = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.org",
                              "-c", "init.defaultBranch=develop", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args)
    raise "git #{args.join(' ')}: #{out}" unless st.success?
    out
  end

  def write(dir, files)
    files.each do |rel, text|
      p = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(p))
      File.write(p, text)
    end
  end

  FEATURES = <<~MD.freeze
    # Ruby features

    | probe | a | b | c | d | e | f | g | app VM std | h |
    |---|---|---|---|---|---|---|---|---|---|
    | `regexp_literal` /a/ | ok | ok | ok | ok | ok | ok | ok | **ng** | x |
    | `array_sum` Array#sum | ok | ok | ok | ok | ok | ok | ok | ng | x |
    | `string_upcase` String#upcase | ok | ok | ok | ok | ok | ok | ok | ok | x |

    - `regexp_literal` on app VM std: NameError: uninitialized constant Regexp
  MD

  SIG_OLD = <<~RBS.freeze
    class FmrbGfx
      # Fill a rectangle<<en>>Fill a rectangle
      def fill_rect: (Integer x, Integer y, Integer w, Integer h, Integer color) -> FmrbGfx
    end
  RBS

  SIG_NEW = <<~RBS.freeze
    class FmrbGfx
      # Fill a rectangle<<en>>Fill a rectangle
      def fill_rect: (Integer x, Integer y, Integer w, Integer h, Integer color) -> FmrbGfx
      # Draw a picture file<<en>>Draw a picture file, reading it in the first time
      def draw_picture: (String path, Integer x, Integer y) -> bool
    end
  RBS

  # Builds core.git and asterism.git under dir; returns their file:// URLs.
  def build(dir)
    core = File.join(dir, "core-src")
    ast = File.join(dir, "asterism-src")
    [core, ast].each { FileUtils.mkdir_p(_1) }
    git(core, "init", "-q", "-b", "develop")
    write(core, {
            "components/fmrb_common/include/fmrb.h" => "#define FMRB_OS_VERSION \"3.0.0\"\n",
            "components/big/blob.c" => "/* not for the AI host */\n" * 100,
            "sig/fmrb_gfx.rbs" => SIG_OLD,
            "sig/README.md" => "# sig\n",
            "flash/lib/templates/window.rb" => "class MyApp < FmrbApp\nend\n",
            "flash/app/demo/pub_demo.app.rb" => "class PubDemo < FmrbApp\n  # pub\nend\n",
            "flash/app/demo/sub_demo.app.rb" => "class SubDemo < FmrbApp\n  # sub\nend\n",
            "flash/app/modern/chat.app.rb" => "class Chat < FmrbApp\n  # FmrbAsterism talk with another device\n  def on_create\n  end\nend\n",
            "flash/app/test/odd.app.rb" => "# FmrbAsterism odd test app\n",
            "flash/app/game/mahjong/table.app.rb" => "# FmrbAsterism mahjong\n",
            "flash/app/game/huge.app.rb" => "# FmrbAsterism huge\n" + ("x = 1\n" * 7000),
            "lib/gems/picoruby-fmrb-asterism/mrblib/asterism.rb" => "class FmrbAsterism\n  def _raw_put\n  end\nend\n",
            "lib/gems/picoruby-fmrb-app/mrblib/fmrb-app.rb" => "class FmrbApp\n  # FmrbAsterism big library\n" +
                                                               ("  x = 1\n" * 6000) + "end\n",
            "lib/gems/picoruby-fmrb-asterism/src/asterism.c" => "/* C: out of scope */ FmrbAsterism\n",
            "flash/usr/share/doc/chat.md" => "# Chat\nFmrbAsterism guide\n",
            "doc/reference/screen_helpers.md" => "# helpers\n",
            "doc/plan.md" => "# a plan: FmrbAsterism (out of scope)\n"
          })
    git(core, "add", "-A")
    git(core, "commit", "-q", "-m", "first")
    git(core, "tag", "-a", "3.0.0", "-m", "3.0.0")
    write(core, { "components/fmrb_common/include/fmrb.h" => "#define FMRB_OS_VERSION \"3.1.0\"\n",
                  "sig/fmrb_gfx.rbs" => SIG_NEW })
    git(core, "commit", "-q", "-am", "draw_picture")
    git(ast, "init", "-q", "-b", "main")
    write(ast, { "docs/ruby_features.md" => FEATURES, "lib/big.rb" => "# not needed\n" })
    git(ast, "add", "-A")
    git(ast, "commit", "-q", "-m", "first")
    { core: "file://#{core}", asterism: "file://#{ast}", core_dir: core, asterism_dir: ast }
  end

  # A new commit on develop (a new API after the first fetch).
  def move_develop(core_dir)
    write(core_dir, { "sig/fmrb_net.rbs" => "class FmrbNet\n  # Send<<en>>Send a text\n  def send_text: (String t) -> bool\nend\n" })
    git(core_dir, "add", "-A")
    git(core_dir, "commit", "-q", "-m", "net")
  end
end
