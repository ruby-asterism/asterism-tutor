# asterism-tutor

Family mruby の「AI に聞く」の、親の PC で動く側。端末 (P4-Nano・Tab5) の AI 連携アプリから
Asterism で頼みを受け、LLM を呼び、コードを検査して返す CRuby の gem。

> 状態: 試作 (fmruby-core の doc/ai_coding)。動きも設定の形も変わる。

```
端末 (AI 連携アプリ) --Asterism のルータ--> asterism-tutor (この gem) --> LLM の API
                                              鍵・知識の束・検査・記録・上限
```

## 大事なこと (親が知っておくこと)

- **端末は LLM の鍵を持たない**。端末が話す相手はこの gem だけで、LLM の提供元とは直接話さない。
  鍵は、この gem を起こすプロセスの環境変数 `ANTHROPIC_API_KEY` にだけ置く (設定のファイル・記録には入らない)。
- **LLM の提供元に送るもの**: 子どもが打った文、エディタの今の文書 (送ると選んだとき・ヒント・直して)、
  直前の実行のエラーの文、同じ端末の直前の数回のやり取り (頼みの短い形と答えの説明)、それと
  この gem の知識の束 (Family mruby のアプリの書き方・API の型・罠の表・見本。子どもの情報は入っていない)。
  端末の名前 (Asterism のノード ID) やファイルの置き場所は、文書の名前を除いて送らない。
- **記録**: 頼み・送った文書・LLM への指示・答え・使った量 (usage) と見積もりの費用・検査の結果を、
  全部 JSONL で `~/.local/share/asterism-tutor/log/tutor-YYYY-MM-DD.jsonl` に残す。gem は消さない。
  親はこれを読める (1 行 1 件の JSON。`ev` が `ask`・`llm`・`check`・`result`・`refused` など)。
- **できることを親が決める**: 受け付ける端末 (`devices`)、1 日の回数と費用の上限、「作る」「直してもらう」を止める。
  AI の役目と決まり (子ども向けの言葉づかい、プログラムの話以外は断る、AI であると言う、分からないことは
  分からないと言う) は `data/rules_ja.md` にあり、束に入って毎回 LLM に渡る。
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
- console など、すでに Asterism の接続を持つプログラムの中では:

  ```ruby
  require "tutor"
  server = Tutor::Server.new(Tutor::Config.load("tutor.toml"))
  server.attach(net)          # net: Asterism.connect の接続。helper を公開する
  ```

## 設定 (`tutor.toml`)

全部の項目と既定は `config/tutor.toml.example`。主なもの:

| 項目 | 既定 | 意味 |
|---|---|---|
| `network.devices` | `["*"]` | 受け付ける端末のノード ID。`*` は全部 (開発用)。素の TCP のルータでは名乗りにすぎない (取り違え防止)。拘束力は mTLS のルータの ACL で持たせる |
| `llm.provider` | `fake` | `fake` (偽物。試験用) か `anthropic` |
| `llm.model` | `claude-haiku-5-5` | `claude-sonnet-5-5` も選べる。単価は `llm.prices` |
| `limits.per_device_per_day` | 50 | 端末ごとの 1 日の回数。超えると理由を返す |
| `limits.cost_per_day_usd` | 1.0 | 全端末の 1 日の費用 (usage からの見積もり)。超えると理由を返す |
| `limits.retries` | 2 | 検査に落ちたコードを LLM に直させる回数 |
| `modes.make` / `modes.fix` | true | 「作る」「直してもらう」を止める |
| `talk.turns` / `talk.forget_min` | 4 / 30 | 会話の続きに付ける往復の数と、忘れるまでの分 |
| `store.result_hours` | 24 | 端末が取りに来ない結果を持つ時間 |
| `store.log_dir` | `~/.local/share/asterism-tutor/log` | 記録の置き場 |

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
「直して」をヒントで頼むときは `mode: "hint"` に `error` を付ける。

## 試験

```sh
bundle exec rake test      # 単体の試験 + ルータ (docker の asterism_tutor_zenohd、127.0.0.1:17520) を立てた通しの試験。LLM は全部偽物
bundle exec rake unit      # ルータなしの分だけ
ruby test/sender.rb --router tcp/127.0.0.1:17520 --node fmruby-test01 ask "変数って何?"   # 手で 1 回頼む (端末の代わり)
```

## 知識の束

`bundles/<ファームの版>/` (今は `3.1.0` だけ)。family-mruby の checkout から作る:

```sh
ruby tools/make_bundle.rb --root /path/to/family-mruby     # bundles/3.1.0/ と bundles/index.json
```

中身: 決まり (`data/rules_ja.md`)、アプリの書き方 (skill `fmrb-app-new`)、API の型 (`sig/*.rbs` の型の行と 1 行の英語の要約)、
エディタの雛形 3 つ、罠の表 (asterism の `docs/ruby_features.md` の app VM の ng・differs)、検査の型 (`checks.json`)、見本 3 つ。
端末の版の束が無ければ、近い古い版の束を使い、記録に `bundle_fallback` を残す。

## 未確認のこと

- 端末 (mruby) からの呼び出し。8 KB の片が端末から通るか、端末が 16 KB 近い答えを受け取れるか (A2 で確かめる)。
- 作ったアプリが端末で本当に動くか (検査は構文と、罠の表にある書き方だけ。型の診断と、実際に動かす確認は無い)。
- `checks.json` の罠の名前の表は、呼び出しの名前で見ているので、自分のクラスに同じ名前のメソッドがあると誤って当たることがある
  (同じ文書の中で `def` したものは外している)。
- 18 歳未満の利用についての提供元の指針が、この使い方に当たるか。
- 公開する形 (gem の名前・リポジトリ・ライセンス)。
