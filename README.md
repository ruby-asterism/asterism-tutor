# asterism-tutor

[Japanese](README.ja.md)

The parent's side of Family mruby's AI helper. A CRuby gem that takes requests from the
AI Helper app on a Family mruby device (P4-Nano, Tab5) over Asterism, calls an LLM, checks
the code that comes back and returns it.

> Status: a prototype (fmruby-core, doc/ai_coding). Its behaviour and its settings will change.

```
device (AI Helper app) --Asterism router--> asterism-tutor (this gem) --> the LLM's API
                                             key, knowledge bundle, checks, log, limits
```

## What a parent should know

- **The device never holds the LLM key.** The device talks to this gem only, never to the
  LLM provider. The key lives only in the environment variable `ANTHROPIC_API_KEY` of the
  process that runs the gem (never in the settings file or the log).
- **What is sent to the LLM provider**: the text the child typed, the editor's current
  document (when the child chose to send it, and for hints and fixes), the error text of the
  last run, the last few exchanges of the same device (the request in short and the answer's
  explanation), and this gem's knowledge bundle (how to write a Family mruby app, the API's
  types, a table of pitfalls, samples; nothing about the child). The device's name (its
  Asterism node ID) and file locations are not sent, except the document's name.
- **The log**: every request, the document sent, the instructions to the LLM, the answer,
  the usage with an estimated cost and the checks' results are kept as JSONL in
  `~/.local/share/asterism-tutor/log/tutor-YYYY-MM-DD.jsonl`. The gem never deletes it.
  A parent can read it (one JSON object per line; `ev` is `ask`, `llm`, `check`, `result`,
  `refused` and so on).
- **The parent decides what is allowed**: the devices that may ask (`devices`), the daily
  limits on requests and cost, and whether "make" and "fix it for me" are on. The AI's role
  and rules (words a child can read, refuse anything that is not about programming, say that
  it is an AI, say so when it does not know) are in `data/rules_ja.md`; they go into the
  bundle and to the LLM with every request.
- The AI does not operate the device. It returns an explanation and the comments or the code
  to put into the editor's document (the device puts them in, after asking and after keeping
  a backup).
- For users under 18, the LLM provider asks organizations to follow additional guidelines.
  Whether they apply as they are to a parent running this for their own child has not been
  checked. Read them before handing this out as an organization (a workshop, for example).

## Running it

Needs Ruby 3.4, docker (the tests' router) and `bundle install` (asterism 0.14, prism 1.9.0,
anthropic 1.80, tomlrb).

```sh
bundle install
cp config/tutor.toml.example tutor.toml      # write only what you change
# without an LLM (a fake one)
bundle exec exe/asterism-tutor --config tutor.toml --llm fake
# with a real LLM (Anthropic): the key goes in the environment only
ANTHROPIC_API_KEY="$(cat path/to/anthropic_api_key)" bundle exec exe/asterism-tutor --config tutor.toml --llm anthropic
```

The model and the limits can be set in the settings file (`llm.model`, `limits.*`) or by
options at start (the options win). At start it prints the model and the limits in one line.

```
bundle exec exe/asterism-tutor --config tutor.toml --llm anthropic --model claude-sonnet-5-5 --per-day 30 --cost-per-day 2
```

- The router is `network.router`. For the zenohd of the Family mruby simulation's stack it is
  `tcp/127.0.0.1:7447` (the same router the device inside the simulation sees as
  `tcp/zenohd:7447`).
- On the network it is `<node>/tutor/helper` (the default node ID is `tutor`). A device looks
  for `*/tutor/helper`.
- To join a TLS router with an Asterism console's certificate (.tar), give the .tar's path
  as `network.credentials`.
- Inside a program that already has an Asterism connection (a console, for example):

  ```ruby
  require "tutor"
  server = Tutor::Server.new(Tutor::Config.load("tutor.toml"))
  server.attach(net)          # net: the connection from Asterism.connect; exposes the helper
  ```

## Settings (`tutor.toml`)

Every key and its default: `config/tutor.toml.example`. The main ones:

| Key | Default | Meaning |
|---|---|---|
| `network.devices` | `["*"]` | The node IDs that may ask. `*` is any (for development). On a plain TCP router an ID is only a claim (it prevents mix-ups); the binding rule is the ACL of an mTLS router |
| `llm.provider` | `fake` | `fake` (for tests) or `anthropic` |
| `llm.model` | `claude-haiku-5-5` | `claude-sonnet-5-5` also works. Prices are in `llm.prices` |
| `limits.per_device_per_day` | 50 | Requests per device per day. Over it, the device gets the reason |
| `limits.cost_per_day_usd` | 1.0 | The cost of all devices per day (an estimate from the usage). Over it, the device gets the reason |
| `limits.retries` | 2 | Times the LLM is asked to fix code that failed the checks |
| `modes.make` / `modes.fix` | true | Turn "make" and "fix it for me" off |
| `talk.turns` / `talk.forget_min` | 4 / 30 | Exchanges kept as the conversation so far, and the minutes until they are forgotten |
| `store.result_hours` | 24 | Hours a result is kept for a device that has not fetched it |
| `store.log_dir` | `~/.local/share/asterism-tutor/log` | Where the log goes |

## What a device calls (`<node>/tutor/helper`)

Every method is `caller: :from` (the caller's node ID tells devices apart). A refusal is not
an exception but `{"error" => kind, "message" => text for the child}`.

| Method | Arguments | Returns |
|---|---|---|
| `hello(info)` | `{"fw", "lang", "host"}` | `{"ok", "modes", "piece", "doc_max", "used", "max", "name"}` |
| `doc_begin(bytes)` | the document's size in bytes | `{"doc" => id}` |
| `doc_piece(doc, i, text)` | the piece's number (from 0) and the piece (up to 8 KB) | `{"have" => bytes received}` |
| `ask(req)` | below | `{"ticket" => id}` |
| `status(ticket)` | | `{"state", "message"}` (`queued`, `thinking`, `checking`, `done`, `failed`, `cancelled`) |
| `result(ticket)` | | `{"kind" => "answer"/"hint"/"doc", "explain", "hints", "left_out", "doc_bytes", "pieces", "base_ver", "bundle"}`; a failure is `{"error", "message"}` |
| `result_piece(ticket, i)` | | `{"i", "text"}` (a piece of the document to put in) |
| `rebase(ticket, doc)` | `{"doc" => id}` or `{"doc_text" => document}`, and `"ver"` | `{"ticket" => new id}` (fits the hints to the document as it is now; no LLM call) |
| `cancel(ticket)` / `ack(ticket)` / `new_talk()` | | `{"ok" => true}` |
| `pending()` | | `[[ticket, state], ...]` (this device's results it has not `ack`ed) |

`req`: `{"mode" => "ask"/"hint"/"make"/"fix", "text", "doc" => id or "doc_text" => document (up to 8 KB), "file", "ver", "cy", "cx", "error", "fw", "lang"}`.
A fix asked for as hints is `mode: "hint"` with `error`.

## Tests

```sh
bundle exec rake test      # unit tests + end-to-end tests with a router (docker, asterism_tutor_zenohd, 127.0.0.1:17520); every LLM is fake
bundle exec rake unit      # only the ones without a router
ruby test/sender.rb --router tcp/127.0.0.1:17520 --node fmruby-test01 ask "What is a variable?"   # one request by hand (in place of a device)
```

## The knowledge bundle

`bundles/<firmware version>/` (only `3.1.0` for now). Made from a family-mruby checkout:

```sh
ruby tools/make_bundle.rb --root /path/to/family-mruby     # bundles/3.1.0/ and bundles/index.json
```

In it: the rules (`data/rules_ja.md`), how to write an app, the API's types (the type lines
of `sig/*.rbs` with one-line summaries), the editor's three templates, the table of pitfalls
(asterism's `docs/ruby_features.md`, the app VM's "ng" and "differs" rows), the checks'
patterns (`checks.json`) and three samples. When there is no bundle for a device's version,
the nearest older one is used and the log gets `bundle_fallback`.

The rules and the bundle's documents are in Japanese (the AI Helper's users are children
who read Japanese).

## Not checked yet

- Whether an app it made really runs on the device (the checks are the syntax and the
  spellings in the table of pitfalls; no type diagnosis, and nothing is run).
- The checks' table of pitfall names looks at the names of calls, so a method of the same
  name in the child's own class can match by mistake (the ones `def`ined in the same document
  are left out).
- Whether the provider's guidelines for users under 18 apply to this use.

## License

MIT (`LICENSE`).
