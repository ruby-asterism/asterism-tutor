
# Family mruby のアプリを書く

置き場所は `fmruby-core/flash/app/<カテゴリ>/<名前>.app.rb` と同名の
`.app.toml` (記述は `.rb` 先頭の `#---fmrb` コメントにも書ける。下の「記述の 2 つの形」)。
アセットを同居させるなら
`flash/app/<カテゴリ>/<名前>/` の専用のディレクトリにしてよい (ランチャーは
3 段目まで走査する)。

## 骨格

```ruby
class MyApp < FmrbApp
  def on_create
    @gfx.set_font(:ja, 12)     # 日本語を出すとき (efontJA_12)
    draw_screen
  end

  def draw_screen
    clear_user_area            # 色を省くとテーマの紙の色。枠と部品の描き直しも中でやる
    @gfx.draw_text(4, 4, "こんにちは", theme_fg)  # (0, 0) は枠の内側の左上
    @gfx.present               # present しないと合成に載らない
  end

  def on_event(ev)             # 窓の移動/閉じるは基底が先に済ませている (super 不要)
    return unless ev[:type] == :key_down
    case ev[:scancode]         # keycode ではなく scancode (HID Usage ID)
    when FmrbConst::KEY_UP then ...
    end
  end

  def on_update                # 戻り値 = 次に呼ばれるまでの ms
    200
  end

  def on_destroy
  end
end
```

- ファイルはクラスを定義するだけ。末尾に `MyApp.new.start` (と begin/rescue) は
  **書かない**: ファイルを読み終えたあと、ランタイムがそのファイルの `FmrbApp` の子を
  作って `start` する。起動や実行中の例外は、エラーの窓とログに出る。
- 起動するクラスは、`.app.toml` (か `#---fmrb` 囲み) に `class = "MyApp"` があれば
  常にそれ (子が 1 つでも)。無ければ、ほかの子の親になっている子 (共通の基底) を除いて
  ちょうど 1 つ残る子。1 ファイルに `FmrbApp` の子を 2 つ以上書くときは `class =` を
  書く。名前が違う・子が無い・決まらないときは、理由がエラーの窓に出る。
- Python (`.app.py`) は今も末尾に `app = MyApp()` / `app.start()` が要る。

`.app.toml`:

```toml
app_handle_name = "my_app"
app_screen_name = "MyApp"
app_screen_name_ja = "マイアプリ"
default_window_mode = "window"     # または "fullscreen"
default_window_width = 200
default_window_height = 150
default_window_pos_x = 10
default_window_pos_y = 20
launcher_visible = true
```

### 記述の 2 つの形

- `.app.toml` (上) と、`.rb` の先頭の `#---fmrb` コメントのどちらにも書ける。
  鍵の名前と意味は同じ。コメントは `.rb` だけ、先頭 512 バイトの中で最初のコードの
  行より前に置く:

  ```ruby
  #---fmrb
  # app_screen_name = "MyApp"
  # default_window_width = 200
  # default_window_height = 150
  #---
  class MyApp < FmrbApp
  ```
- **両方あるときは鍵ごとに合わせ、両方にある鍵は `.app.toml` が勝つ**。
- 読み手は C の 1 つ (spawner)。ランチャー・デスクトップ・Shell・checkpoint もそこに
  問う。Ruby から読むなら `FmrbApp.app_meta(path)` (文字列の Hash、アプリでなければ nil)。
  `.app.toml` を自分で開いて行を読まない。
- ランチャーは `.app.toml` の無い `<名前>.app.rb` もコメントを探して拾う。
- 配布 (App Store) するアプリには `.app.toml` が要る (`app_id` などの導入の記録)。
- 鍵の一覧は fmruby-core/doc/app-distribution/spec.md 3.1 節、2 つの形は 3.3 節。

### 鍵のあれこれ

- 窓サイズは画面に収まる値にする (Retro 320x240 / Modern 426x240。P4-Nano の
  既定は 640x360 だが、426x240 に収まる大きさなら両方で出る)。
- 起動が重い/スタックが要るときは `task_stack_kb` を書ける。
- 同時に 2 つ動いては困るアプリは宣言で断れる (エラーの窓が出る。書かなければ
  何個でも開ける):
  - `single_instance = true`: 同じファイルの 2 つ目を断る。
  - `exclusive_group = "fft"`: 同じ値を書いたアプリが動いている間は断る
    (自分の 2 つ目も断る)。1 つしか無い資源 (Spinel gem のインスタンス、
    C の共有バッファなど) を取り合うアプリどうしに書く。名前は 15 バイトまで。
  - 鍵の一覧は fmruby-core/doc/app-distribution/spec.md 3.1 節。
- Linux 版のキーボード専用のデスクトップ (Cardputer Zero の 320x170) のメニューに
  出すには、最初の `[表]` より前に 2 つ書く (書かないアプリは出ない):
  - `screens = ["426x240", "320x170"]`: 描ける画面の形。320x170 ではアプリは
    帯の下の 320x160 の全画面で動くので、`@window_width` / `@window_height`
    (と `on_resize`) から配置を決め、その大きさで読めるアプリにだけ書く。
  - `needs_pointer = false`: マウス・タッチなしで全部の操作ができる。書いて
    いないアプリはマウスが要るものとみなされる。
  - 鍵の表は fmruby-core/doc/app-distribution/spec.md 3.1 節。
- 全画面のアプリの画面の大きさ (Modern の画面は 426x240 か 640x360。P4-Nano の
  既定は 640x360、Tab5・sim・ブラウザ版は 426x240)。宣言は 2 つ:
  - 何も書かない: 426x240 向けとして扱う。426x240 の画面ではそのまま、
    640x360 の画面ではこのアプリが全画面の一番上にいる間だけ画面が 426x240
    (3 倍) に切り替わり、426x240 のときと同じ絵になる。固定の配置で描く
    ゲーム・デモはこれでよい。
  - `fullscreen_hires = true`: 全画面で細かく描きたいアプリ (エディタ型)。
    426x240 の画面では全画面の間だけ 640x360 になり、640x360 の画面では
    切り替えずにそのまま 640x360。
  - `fullscreen_any_size = true`: 届いた大きさから配置を決めるアプリ。
    640x360 の画面でも 426x240 に切り替えず、640x360 の全画面で動く
    (426x240 の画面では何も変わらない)。`@window_width` / `@window_height`
    と `on_resize` から配置を決めること (固定の座標が残ると左上に寄る)。
  - どちらの宣言でも大きさは `on_resize` で受けて組み直す。詳細は
    fmruby-core/doc/reference/fullscreen_hires.md。

## 描画

- **背景と文字はテーマから取る**: `clear_user_area` (引数なし = 紙の色)、
  文字は `theme_fg`、薄い字や枠は `theme_border`、強調は `theme_accent`、
  濃い地の上の字は `theme_fg_light`。色は `system_conf.toml` の `[theme]`
  1 か所で決まり、デスクトップと全アプリが一緒に変わる (Retro の NTSC で
  白が強ければそこで落とす)。**黒地に白字をベタ書きしない**: 基調は白なので
  `FmrbGfx::WHITE` の字は消える。
- 自分で色を決めてよいのは、画面そのものが作品のアプリ (ゲーム、スペクトル、
  LED 表示など)。そのときは `clear_user_area(FmrbGfx::BLACK)` のように
  **明示して**、意図だと分かるようにする。
- 黄・シアン・明るい緑は白地で読めない。色分けが要るなら暗めの値
  (橙 0xE8、濃緑 0x14、青 0x03 など) を使う。
- 色は RGB332。`FmrbGfx::WHITE` 等はメソッド内で使える。クラス本体の
  定数表に書くなら数値リテラルか `FmrbConst::THEME_*` にする (bare 定数の
  探索で落ちるため。`FmrbConst::` は付けて書けば定数表でも使える)。
- 日本語は `set_font(:ja, 12)` (全角 12px / ASCII 6px) か `(:ja, 8)` (misaki)。
  **`draw_text(..., mixed: true)` は使わない**: ASCII=Font0 / 全角=misaki_8 に
  固定される経路で、set_font の選択を無視して漢字が 8px に落ちる。
  混在文字列は素の `draw_text` でそのまま正しく出る。
- 毎ターン全面を描き直さない。変わったところだけ描く (draw 命令は 1 個ずつ
  グラフィックス側へ送られる)。
- Sprite を動かしたら `@gfx.present` (合成は present 時に走る)。
- **座標は「アプリが描いてよい区画」の左上が (0, 0)** (`@gfx` もマウスの
  `ev[:x]`/`ev[:y]` も FmrbUI も同じ)。枠のある窓は枠の内側、枠なし
  (`window_frame = "none"`)・全画面は窓の左上。`@user_area_x0 +` のような
  足し算は書かない (その ivar は無い)。区画の大きさは `@user_area_width` /
  `@user_area_height`。全画面の出入り・大きさ変更で原点は基底が持ち直すので、
  `on_resize` では描き直すだけ。スプライトと `set_sprite_clip` も区画の座標。
- 区画の外 (枠の上・自前のタイトル) に描くときは `@window_gfx` (原点が窓の
  左上)。窓の左上からのマウスの位置は `ev[:wx]`/`ev[:wy]` (閉じるボタンの
  上かどうか、など)。書体は canvas 共通なので `set_font` は `@gfx` で呼ぶ。
- **全面を消すのは `clear_user_area`**。枠は基底が描き直すので
  `draw_window_frame` を自分で呼ばない (`@gfx.clear` や Window 全体の `fill_rect`
  で消すと枠ごと消えるので、それはしない)。その user area に置いた FmrbUI の部品も
  基底が描き直しの印を付ける (`invalidate_all` を自分で呼ぶ必要は無い)。

## ボタンや切替がいる画面 (FmrbUI)

当たり判定・押した見た目・描き直しを自分で書かない。実装は
`lib/gems/picoruby-fmrb-app/mrblib/fmrb-ui.rb`、型は `sig/fmrb_ui.rbs`。

```ruby
def on_create
  @ui = FmrbUI.new(self)                  # bg: は部品が自分の中を塗る色。既定はテーマの紙の色
  @ui.toggle(:red, 4, 4, 50, 16, "赤", group: :color, on: true)
  @ui.button(:go, 4, 24, 50, 16, "GO")
  @st = @ui.stepper(:size, 4, 44, 108, 14, 5, 1, 9)
  @ui.enum(:theme, 4, 62, 90, 14, ["light", "dark"])   # 選択肢は < > で送る
  clear_user_area
  @ui.flush
end

def on_event(ev)
  case @ui.handle(ev)                     # 座標は user area の左上が原点
  when :red  then @color = FmrbGfx::RED
  when :go   then start_something
  when :size then @size = @st.value
  when :theme then apply(@ui.option_text(:theme))
  when nil   then return @ui.flush        # 押下表示を戻すだけ
  end
  draw_picture                            # 自分の絵
  @ui.flush                               # present はここだけ、1 回
end
```

部品は Label / Button / Toggle / Stepper / Enum / Scrollbar / TextField。
スクロールバーは `(全体数, 見えている数, 位置)` の 3 整数だけで動き、
一覧の中身は知らない。文字入力欄はクリックで焦点が移り、Enter で id を返す。

- **毎フレーム描かない**。部品は `on_create` で作り、`flush` が dirty な
  ものだけ描く。`on_update` から描かない。
- **ブロックを渡さない**。`handle` が返す id を `case` で受ける
  (Spinel は保存したブロックの外側ローカルを捕まえられない)。
- **poly 受信で呼ぶメソッド名はプログラム全体で一意にする**。Spinel は
  基底型の受信に対する候補を**メソッド名で**引くので、`draw` のような
  ありふれた名前は同名の別クラスのメソッド (`GfxBlock#draw`) まで巻き込み、
  到達不能でもビルドが落ちる。FmrbUI の描画が `draw_widget` なのはこのため。
- **`bg:` は部品が自分の中を塗る色**。Label の箱、Stepper の値の欄、
  Scrollbar の溝で、**後ろにあるものの色ではない**。部品を隠したときの跡も
  既定ではこの色で塗られるので、地が絵 (壁紙・枠線・角の丸み) のアプリは
  `bg_painter:` に自分を渡し、`paint_bg_rect(gfx, x, y, w, h)` でその矩形を
  自分で描く。実装は**描くだけ**: present しない、確保しない、文字サイズや
  フォントを変えたら戻す。名前は固定 (poly 受信のため)。
- **区画の外に部品を置くと生成時にログに出る**
  (`FmrbUI: widget <id> outside the area (x,y,w,h)`)。座標は `@gfx` と同じ
  (区画の左上が原点)。
- **`text_width` は family を明示する** (`text_width(str, :default)`)。
  省略すると「直前に選ばれていたフォント」で測るので、`set_font(:ja)` の
  あとに測ると幅がずれる。文字の大きさも同じ理屈で、FmrbUI の部品は
  `text_size:` (既定 1) を生成時に固定し、`flush` がアプリの size を
  元に戻す — アプリ側でページごとに `set_text_size` を変えてよい。
- FmrbUI の部品 (ラベル・ボタン・切替・Stepper・Enum) は、箱に収まらない
  文字を自分で `..` に詰める。アプリ側で切らずにそのまま渡す。

## 毎回まるごと描く画面のボタン・長い文字 (FmrbGfx + HitAreas)

ゲームの卓のように画面を毎回描き直すなら FmrbUI の部品ではなく、
**描いて、登録する**の 2 行にする。使い分けの正は
`fmruby-core/doc/reference/screen_helpers.md`。

```ruby
@hits = FmrbUI::HitAreas.new             # on_create で 1 回
# 描くたびに:
@hits.clear
@gfx.draw_button(x, y, 60, 16, "OK", fill, fg)   # 角丸のボタンの絵だけ
@hits.add(:ok, x, y, 60, 16)                       # 押せる範囲だけ (描かない)
# on_event で:
id = @hits.id_at(ev[:x], ev[:y])
```

- 長い文字は自前で `[0, n]` と字数で切らない。幅 (px) で
  `@gfx.fit_text(str, width, "..")` (収まればそのまま返る)、2 行に折るなら
  `wrap_text` / `draw_text_lines`。
- ボタンの一覧を作ったら変えない画面は、その一覧で当たり判定すればよく、
  HitAreas に写さない (同じ物を 2 か所に持つと VM の使用量が増える)。

## アプリ間通信 (Pub/Sub)

```ruby
subscribe("topic")            # on_create で / on_destroy で unsubscribe
publish("topic", { "k" => 1 })

def on_control(msg)
  if msg["cmd"] == "topic_data" && msg["topic"] == "topic"
    data = msg["data"]        # キーは String で届く (Symbol にならない)
  end
end
```

- **publisher 自身には届かない**。**保持 (retained) は無い**ので、後から
  起動した購読者のために周期的に流すか、状態を毎回載せる。
- 往復は Linux sim で 0-1 ms。実機は未計測。

## 関連付けで開かれる (ファイルを受け取る)

`/etc/associations.toml` が拡張子ごとに「どのアプリで開くか」を持っている
(ユーザは `/home/associations.toml` で上書き)。そこに自分のアプリを書けば、
file manager のダブルクリックと shell の `open` から呼ばれる。

```ruby
def on_control(msg)
  return unless msg["cmd"] == "file_selected"
  load_it(msg["path"])   # 起動直後に 1 回届く
end
```

- **受けなければ何も起きない**。アプリはただ起動するだけで、それで良い。
- 同じ `file_selected` は「ファイルを開く」ダイアログの結果にも使われる
  (`request_file_select`) ので、受け口は 1 つで済む。

## 枠なしの Window (アバター・マスコット)

- `.app.toml` に `window_frame = "none"`。基底が枠・タイトルバー・閉じるボタンを
  描かず、user area = Window 全体、地は透ける色 (Window 全体が透ける区画)。
  アプリは絵を描いて `present` するだけ。`set_composite_regions` や
  `@gfx.clear(TRANSPARENT_COLOR)` を自分で書かない (移った後も基底が掛け直す)。
- 動かすのはカーネル: 既定の `window_drag = "anywhere"` でどこを掴んでも動く。
  押しただけならクリック (押下と離しが離したときに続けて届く)。動かさずに 1 秒
  押し続けると長押し (Window のメニュー)。長押しを自分で使うなら `window_drag = "none"`。
- 右クリック・長押しは `on_frameless_right_click(ev)` (長押しは
  `ev[:type] == :long_press`)。既定は Window のメニュー (送る・読み直し・閉じる、
  枠つきのタイトルバーの右クリックと同じ)。右ボタンを使うなら上書きする (空なら
  メニューは出ない、`super(ev)` でメニューも)。ほかの閉じ方は Ctrl+Q・Shell の kill。
- 当たりは申告する: `set_hit_shape([[x, y, w, h], ...])`、
  `set_hit_mask(hit_mask_from_art(ROWS, transparent: ".", scale: 3), x, y)`、
  `add_hit_sprite(sprite)`。その和の外の押下は後ろの Window・デスクトップへ抜ける。
  申告しなければ Window の四角全体が当たる。絵を変えたら形も申告し直す
  (見た目とは独立)。`amove` では矩形とマスクは運ばれ、sprite の印は `on_restore`
  で付け直す。
- 鍵の説明は fmruby-core/doc/app-distribution/spec.md 3.4 節。
- 見本は `flash/app/demo/avatar.app.rb` (movable のアバター。絵は文字列、変わった行だけ描く)。

## 動いたまま別の端末へ運ぶ (movable)

- `.app.toml` に `movable = true`、端末ごとに違うメソッドへの備え、`requires`、
  `on_restore` での描き直しなどの決まりは fmruby-core/doc/checkpoint/movable_apps.md。

## FmrbApp と FmrbSystem のクラスメソッド

- アプリが使うもの (`FmrbApp.ps`・`pid`・`wifi_info`・`battery_level`・`audio_volume`・
  `clipboard`・`wallclock` など、状態を読むもの) は `FmrbApp`。
- 端末の設定とサービスを**変える**もの (Wi-Fi・BLE・電源・時計を合わせる・音の設定・
  PC の設定と知らせ) は `FmrbSystem` (`FmrbSystem.reboot`・`set_audio_mute`・
  `wifi_connect` など)。デスクトップと設定のアプリのためのもので、`FmrbApp.<それ>` と
  書くと mruby では呼んだ所で NoMethodError (`rake system:check` が止める)。
- 型とヘルプは `sig/fmrb_app.rbs` と `sig/fmrb_system.rbs`。

## picoruby の地雷

- **ブロック呼び出しが重い** (~0.4ms/回)。数十回以上のループは `each` でなく
  `while`。`Array#include?` は Ruby 実装で 1.7ms — `index` か比較の並記に。
- `defined?` 無し / `File.binread` 無し / `Array#pack` 無し
  (`"\x00" * n` + `setbyte`/`getbyte`)。
- クラス内の bare 定数 (`JSON`, `File` 等) は `Class::JSON` として探されて
  落ちる。`::JSON` と書く。
- 配列要素を左辺に置く多重代入 (`a[i], a[j] = a[j], a[i]`) は壊れる。一時変数で。
- 時間は `Machine.board_millis` (実時間)。フレーム数で数えない。
  一度だけ後で呼ぶなら `id = set_timer(ms) { ... }`、取り消しは `clear_timer(id)`。
  `sleep_ms` は `_spin` の外では止まる — `Machine.delay_ms` を使う。
- mruby の `String#length` は UTF-8 文字数。バイナリは `bytesize`/`getbyte`。
