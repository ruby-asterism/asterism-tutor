# asterism-tutor

[English](README.md)

Family mruby の「AI に聞く」の、親の PC で動く側。端末 (P4-Nano・Tab5) の AI 連携アプリから
Asterism で頼みを受け、LLM を呼び、コードを検査して返す CRuby の gem。親の PC でも、
サーバの Asterism console の隣のコンテナとしても動く ([docs/install.md](docs/install.md)、英語)。

> 状態: 試作 (fmruby-core の doc/ai_coding)。動きも設定の形も変わる。

```
端末 (AI 連携アプリ) --Asterism のルータ--> asterism-tutor (この gem) --> LLM の API
                                              鍵・知識の束・検査・記録・上限
```

## 大事なこと (親が知っておくこと)

- **端末は LLM の鍵を持たない**。端末が話す相手はこの gem だけで、LLM の提供元とは直接話さない。
  鍵は、この gem を起こすプロセスの環境変数 `ANTHROPIC_API_KEY` にだけ置く (設定のファイル・記録には入らない)。
- **LLM の提供元に送るもの**: 子どもが打った文、エディタの今の文書 (送ると選んだとき・ヒント・修正)、
  直前の実行のエラーの文、同じ端末の直前の数回のやり取り (頼みの短い形と答えの説明)、それと
  この gem の知識の束 (Family mruby のアプリの書き方・API の型・罠の表・見本。子どもの情報は入っていない)。
  LLM が調べ物をしたときは (下)、Family mruby のソースから見つけた行も送る。
  端末の名前 (Asterism のノード ID) やファイルの置き場所は、文書の名前を除いて送らない。
- **記録**: 頼み・送った文書・LLM への指示・答え・使った量 (usage) と見積もりの費用・検査の結果を、
  全部 JSONL で `~/.local/share/asterism-tutor/log/tutor-YYYY-MM-DD.jsonl` (コンテナでは volume の `log/`) に残す。gem は消さない。
  親はこれを読める (1 行 1 件の JSON。`ev` が `ask`・`llm`・`check`・`result`・`refused` など)。
- **できることを親が決める**: 受け付ける端末 (`devices`)、1 日の回数と費用の上限、「作成」「修正してもらう」を止める。
  AI の役目と決まり (子ども向けの言葉づかい、プログラムの話以外は断る、AI であると言う、分からないことは
  分からないと言う) は `data/rules_ja.md` にあり、束に入って毎回 LLM に渡る。
- **知識の元**: gem は公開の Family mruby のソース (GitHub の fmruby-core と asterism) を clone して持ち、
  端末のファームの版 (リリースのタグ、開発中の版なら `develop`) の束をそこから作る。取るのは起動のときと
  1 日 1 回。取れないときは手元のものを使い続け、まだ何も取れていなければ gem に同梱の束を使う。
  LLM はそのソースを検索して読むこともできる (読むだけ・`sources.search` の範囲だけ・1 回の頼みで 4 往復まで)。
  `git` と GitHub への通信が要る。`sources.enabled = false` で止まる (同梱の束だけ、調べ物なし)。
- AI は端末を操作しない。返すのは説明の文と、エディタの文書に入れるコメントかコードだけ
  (入れるのは端末の側。入れる前の確認・退避も端末の側)。
- 18 歳未満の利用について、LLM の提供元は組織に追加の指針を求めている (fmruby-core の
  doc/ai_coding/report/a0.md 7.5)。親が自分の子のために動かす形にそのまま当たるかは確認していない。
  ワークショップなどで組織として配るなら、その指針を読むこと。

## 起こし方

要るもの: Ruby 3.4、docker (試験のルータ)、`bundle install` (asterism 0.14・prism 1.9.0・anthropic 1.80・tomlrb)。

```sh
bundle install
cp config/tutor.toml.example tutor.toml      # 直すところだけ書けばよい
# LLM なし (偽物の LLM) で動かす
bundle exec exe/asterism-tutor --config tutor.toml --llm fake
# 本物の LLM (Anthropic) で動かす: 鍵は環境変数で渡すだけ
ANTHROPIC_API_KEY="$(cat path/to/anthropic_api_key)" bundle exec exe/asterism-tutor --config tutor.toml --llm anthropic
```

モデルと上限は、設定のファイル (`llm.model`・`limits.*`) でも、起こすときのオプションでも変えられる
(オプションが先)。起こしたときに、今のモデルと上限を 1 行で出す。

```
bundle exec exe/asterism-tutor --config tutor.toml --llm anthropic --model claude-sonnet-5-5 --per-day 30 --cost-per-day 2
```


- ルータは設定の `network.router`。sim の stack の zenohd につなぐなら `tcp/127.0.0.1:7447`
  (sim の中の端末からは `tcp/zenohd:7447` に見える同じルータ)。
- 網の上では `<node>/tutor/helper` になる (既定のノード ID は `tutor`)。端末は `*/tutor/helper` で探す。
- Asterism console の証明書 (.tar) で TLS のルータにつなぐなら `network.credentials` に .tar のパス。
- `asterism-tutor status` は、動いている gem (同じ設定) がルータにつながり helper を公開できているかを返す。
  できていれば 0、できていなければ 1 (ルータがいない、止まるところ)、新しい状態が無ければ 2 (動いていない、固まった)。
  gem が 2 秒ごとに書く `<state_dir>/status.json` を読む (port は開かない)。
- SIGTERM (と Ctrl-C): 新しい頼みは断り (端末には「止まるところ」と返す)、進行中の頼みは `jobs.stop_grace_s` (8 秒)
  待ち、残ったものは `stopped` の失敗にする。端末は gem が戻ってから `status`・`result`・`pending` でそれを読む。
  殺された gem が残した進行中の頼みも、次に起こしたときに同じ失敗にする。
- 起こし直しても残るもの: 記録 (`log_dir`)、端末が取りに来ていない結果 (`<state_dir>/tickets/`、頼みごとに 1 ファイル)、
  その日の回数と費用 (記録から読み戻す)。片で送られている途中の文書と会話の続き (どうせ `talk.forget_min` で忘れる) は残らない。
- console など、すでに Asterism の接続を持つプログラムの中では:

  ```ruby
  require "tutor"
  server = Tutor::Server.new(Tutor::Config.load("tutor.toml"))
  server.attach(net)          # net: Asterism.connect の接続。helper を公開する
  ```

## 設定 (`tutor.toml`)

全部の項目と既定は `config/tutor.toml.example`。オプションが環境変数より先、環境変数がファイルより先、ファイルが既定より先。主なもの:

| 項目 | 既定 | 意味 |
|---|---|---|
| `network.devices` | `["*"]` | 受け付ける端末のノード ID。`*` は全部 (開発用)。素の TCP のルータでは名乗りにすぎない (取り違え防止)。拘束力は mTLS のルータの ACL で持たせる |
| `llm.provider` | `fake` | `fake` (偽物。試験用) か `anthropic` |
| `llm.model` | `claude-haiku-5-5` | `claude-sonnet-5-5` も選べる。単価は `llm.prices` |
| `limits.per_device_per_day` | 50 | 端末ごとの 1 日の回数。超えると理由を返す |
| `limits.cost_per_day_usd` | 1.0 | 全端末の 1 日の費用 (usage からの見積もり)。超えると理由を返す |
| `limits.retries` | 2 | 検査に落ちたコードを LLM に直させる回数 |
| `modes.make` / `modes.fix` | true | 「作成」「修正してもらう」を止める |
| `talk.turns` / `talk.forget_min` | 4 / 30 | 会話の続きに付ける往復の数と、忘れるまでの分 |
| `store.result_hours` | 24 | 端末が取りに来ない結果を持つ時間 |
| `store.log_dir` | `~/.local/share/asterism-tutor/log` | 記録の置き場 |
| `store.state_dir` | `~/.local/share/asterism-tutor/state` | 取りに来ていない結果 (`tickets/`) と `status.json` |
| `jobs.stop_grace_s` | 8 | SIGTERM のとき、進行中の頼みを待つ秒数 |
| `sources.enabled` | true | Family mruby のソースを clone して束をそこから作る (false: 同梱の束、調べ物なし) |
| `sources.dir` | `store.state_dir` の隣の `sources` | clone と、そこから作った束の置き場 (2 つの版で約 7 MB) |
| `sources.core` / `sources.asterism` | GitHub の公開のリポジトリ | clone の元 (git の URL かパス) |
| `sources.branch` | `develop` | リリースのタグが無い版のときの fmruby-core の ref |
| `sources.search` | `sig/**/*`・`flash/app/**/*`・`lib/gems/*/mrblib/**/*`・`flash/usr/share/doc/**/*`・`doc/reference/**/*` | LLM が検索して読める範囲 (fmruby-core の中の glob) |
| `sources.exclude` | `flash/app/test/**/*`・`flash/app/game/mahjong/**/*` | 範囲から外すもの (clone もしない) |
| `sources.rb_max_kb` | 32 | これより大きい `.rb` も範囲から外す |
| `sources.refresh_hours` | 24 | 取り直す間隔 |
| `lookup.rounds` | 4 | 1 回の頼みで調べられる往復の数 (0: 道具なし)。使い切ったら、そこまでの材料で答える |
| `lookup.hits` / `lookup.lines` | 30 / 120 | 1 回の検索で返す行の数 / 1 回に読める行の数の上限 |

環境変数 (コンテナの `.env`。空の値は無いのと同じ) の一覧は README.md の "Settings" の表。名前は `ASTERISM_TUTOR_*`
(`ROUTER`・`CREDENTIALS`・`NODE`・`DEVICES`・`LLM`・`MODEL`・`PER_DAY`・`COST_PER_DAY`・`LOG_DIR`・`STATE_DIR`・`MAKE`・`FIX`・
`STOP_GRACE`・`SOURCES`・`SOURCES_DIR`・`LOOKUP_ROUNDS`、設定のファイルは `ASTERISM_TUTOR_CONFIG`)。LLM の鍵は今のまま `ANTHROPIC_API_KEY` だけ。
上限の「1 日」(と記録のファイルの日付) は、プロセスの地方時 (`TZ`) の日付。コンテナの既定は `Asia/Tokyo`
(`deploy/vps/.env` の `TUTOR_TZ`)。AI ホストが止まったせいで失敗した頼み (`stopped`) は、その日の回数に数えない (LLM の費用は数える)。

## 端末から呼ぶ形 (`<node>/tutor/helper`)

全部 `caller: :from` (呼んだ端末のノード ID で見分ける)。断るときは例外でなく `{"error" => 種類, "message" => 子ども向けの文}`。

| メソッド | 引数 | 返り値 |
|---|---|---|
| `hello(info)` | `{"fw", "lang", "host"}` | `{"ok", "modes", "piece", "doc_max", "used", "max", "name"}` |
| `doc_begin(bytes)` | 文書のバイト数 | `{"doc" => id}` |
| `doc_piece(doc, i, text)` | 片の番号 (0 から) と片 (8 KB まで) | `{"have" => 受け取ったバイト数}` |
| `ask(req)` | 下 | `{"ticket" => id}` |
| `status(ticket)` | | `{"state", "message"}` (`queued`・`thinking`・`checking`・`done`・`failed`・`cancelled`) |
| `result(ticket)` | | `{"kind" => "answer"/"hint"/"doc", "explain", "hints", "left_out", "doc_bytes", "pieces", "base_ver", "bundle"}`。失敗は `{"error", "message"}` |
| `result_piece(ticket, i)` | | `{"i", "text"}` (入れ替える文書の片) |
| `rebase(ticket, doc)` | `{"doc" => id}` か `{"doc_text" => 文書}` と `"ver"` | `{"ticket" => 新しい id}` (ヒントを今の文書に合わせ直す。LLM は呼ばない) |
| `cancel(ticket)` / `ack(ticket)` / `new_talk()` | | `{"ok" => true}` |
| `pending()` | | `[[ticket, state], ...]` (この端末宛ての、まだ `ack` していないもの) |

`req`: `{"mode" => "ask"/"hint"/"make"/"fix", "text", "doc" => id か "doc_text" => 文書 (8 KB まで), "file", "ver", "cy", "cx", "error", "fw", "lang"}`。
「修正」をヒントで頼むときは `mode: "hint"` に `error` を付ける。

## 試験

```sh
bundle exec rake test      # 単体の試験 + ルータ (docker の asterism_tutor_zenohd、127.0.0.1:17520) を立てた通しの試験。LLM は全部偽物
bundle exec rake unit      # ルータなしの分だけ
ruby test/sender.rb --router tcp/127.0.0.1:17520 --node fmruby-test01 ask "変数って何?"   # 手で 1 回頼む (端末の代わり)
ruby test/sender.rb --credentials fmruby-aaaaaa.tar ask "変数って何?"   # console の証明書で mTLS のルータ越しに
```

## 知識の束と調べ物

頼みには毎回、ファームの 1 つの版の束を付ける: 決まり (`data/rules_ja.md`)、アプリの書き方 (`data/app_guide.md`、skill
`fmrb-app-new`)、API の型 (`sig/*.rbs` の型の行と 1 行の英語の要約)、エディタの雛形、罠の表 (asterism の
`docs/ruby_features.md` の app VM の ng・differs)、検査の型 (`checks.json`)、見本 3 つ。同じソースからは 1 バイトも
違わない束ができる (毎回の頼みのキャッシュされる部分)。作るのは `lib/tutor/bundle_maker.rb`。

どこから取るか (`Tutor::Knowledge`):

1. `bundle.dir` があれば、親が用意した束 (`index.json`・`<fw>/`)。
2. 無ければソース (`Tutor::Sources`): 端末の版の fmruby-core (同じ名前のリリースのタグ、無ければ `sources.branch`) と
   asterism の `main` を、浅く・部分的に・必要なパスだけ (束の分と検索の範囲。`components/` と submodule は取らない)
   `sources.dir` に clone する。ref ごとに 1 つの写し。更新はコミットが変わったときだけ隣に clone して差し替え、
   進行中の頼みは始めたときの写しを使い続ける。取るのは起動のとき・`sources.refresh_hours` ごと・ある版を初めて
   聞かれたとき。アプリの書き方は公開のリポジトリに無いので、gem の写しを使う。
3. 取れない (ネットが無い・GitHub が落ちている・まだ取っていない): 手元の写し、それも無ければ gem に同梱の束
   (`bundles/<fw>/`。端末の版の束が無ければ近い古い版を使い、記録に `bundle_fallback` を残す)。

記録の `knowledge` に頼みごとの元 (ref とコミット)、`sources` に取りに行った結果 (秒・ディスク、または失敗の理由) が
残る。`asterism-tutor status` も写しと取った時刻、最後の失敗を出す。

ソースがあるとき、LLM は道具を 2 つ持つ: `search_source` (文字列か Ruby の正規表現で `sources.search` の範囲を検索。
「パス:行番号: 行」で `lookup.hits` 行・1 行 200 文字まで) と `read_source` (検索に出たパスと行の範囲。`lookup.lines` 行まで)。
読むだけで、範囲の外には出られない: パスは範囲の中の普通のファイルの一覧 (シンボリックリンクをたどらずに作る) で
引くので、`..`・絶対パス・リンクでほかのファイルに届かない。LLM の文字列を外部のコマンドに渡さない。1 回の頼みで
`lookup.rounds` 往復まで (`llm.timeout_s` の残りが 3 分の 1 を切ったら、それ以上は調べない)。使い方の決まりは
`data/tools_ja.md` (束で足りればすぐ答える、型か見本・案内が使っているものだけを使う、調べた中身を子どもに見せない)。
往復ごとに記録に残り (`llm` の `round`・`tool_calls`、`tool` に何を検索したか・どこを読んだか・何を返したか)、
費用は 1 日の上限に数える。`result` の `used` に、その頼みの往復・呼び出しの数・トークン・費用。

gem に同梱の束は family-mruby の checkout から作る (checkout の skill から `data/app_guide.md` も作り直す):

```sh
ruby tools/make_bundle.rb --root /path/to/family-mruby     # bundles/3.1.0/ と bundles/index.json
```

## サーバで動かす

`deploy/vps/` で、Asterism console の隣のコンテナとして動かす (イメージは `ghcr.io/ruby-asterism/asterism-tutor`。
タグ `v<版>` で `.github/workflows/image.yml` が作る)。自分の証明書でルータにつなぎ、使える端末は console の
ルータの役割で決める。手順は [docs/install.md](docs/install.md) (英語)。

## 未確認のこと

- 作ったアプリが端末で本当に動くか (検査は構文と、罠の表にある書き方だけ。型の診断と、実際に動かす確認は無い)。
- `checks.json` の罠の名前の表は、呼び出しの名前で見ているので、自分のクラスに同じ名前のメソッドがあると誤って当たることがある
  (同じ文書の中で `def` したものは外している)。
- 18 歳未満の利用についての提供元の指針が、この使い方に当たるか。

## ライセンス

MIT (`LICENSE`)。
