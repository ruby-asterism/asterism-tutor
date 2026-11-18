# The tutor on a server

asterism-tutor (the parent's side of Family mruby's AI helper) as a
container next to an Asterism console on a server (a VPS), so that the
devices' AI Helper app works without a PC of the parent's running the gem.
The devices keep their usual router (the console's); only those with the
console's role `tutor` reach the helper. The console's installation comes
first: its `docs/install.md`, with its `deploy/vps` running as the compose
project `asterism`.

Names and addresses below are placeholders: `router.example.org` for the
console's router, `fmruby-aaaaaa` for a device, `/srv/asterism` for where
the checkouts are.

## 1. What runs

```
 devices (AI Helper, role "tutor") --tls/router.example.org:7448, their own certificates--> zenohd
                                                                                              ^
 asterism-tutor (project "asterism-tutor")                                                    |
   one process ------------------------------------TLS as tutor (its own .tar) ---- tls/zenohd:7448
     exposes tutor/tutor/helper                    (the console's network asterism_router)
     calls the LLM's API over https (ANTHROPIC_API_KEY in .env)
   /state (its volume): log/    the records (JSONL, one file a day; never deleted, not backed up)
                        store/  the results not fetched yet, status.json
   /credentials (deploy/vps/credentials/, read-only): tutor.tar
```

- A compose project of its own (`deploy/vps/docker-compose.yml`, project
  `asterism-tutor`): the console's and the game host's `update.sh` never
  touch it. It uses the console's network `asterism_router` by name and
  publishes no port: nothing changes for nginx, the firewall or DNS.
- The LLM key is in `deploy/vps/.env` only (`ANTHROPIC_API_KEY`): a key of
  the tutor's own, not the game host's, so its cost is seen and stopped
  apart. It is not in the image, the records or the log.
- The records are not in the console's daily backup (they stay in the
  tutor's volume only).

## 2. What you need

- The console 0.4.0 or later running (`docker compose ps` in its
  `deploy/vps`).
- About 256 MB of free memory and 250 MB of disk for the image.
- git and Docker with compose v2.24 or later, as for the console.
- An LLM key for the tutor (Anthropic), made for it alone.

## 3. The console's side

In the console (Admin > Relay):

1. **Roles > New role `tutor-host`** (the tutor itself):
   - Read and write:
     ```
     asterism/${node}
     asterism/${node}/tutor/**
     asterism/${node}/@profile
     asterism/${node}/tutor/@profile
     asterism/${node}/tutor/@status
     asterism/${node}/tutor/@pubs
     ```
   - Read: none. Ask: none.
   - Watch: `asterism/**`
   - Not for browsers.
2. **Roles > New role `tutor`** (the devices that may ask):
   - Read and write (the device's own AI Helper app, `ai_helper`):
     ```
     asterism/${node}
     asterism/${node}/ai_helper/**
     asterism/${node}/@profile
     asterism/${node}/ai_helper/@profile
     asterism/${node}/ai_helper/@status
     asterism/${node}/ai_helper/@pubs
     ```
   - Read (the helper's tokens, so the app finds `*/tutor/helper`, and the
     answers to its calls):
     ```
     asterism/*/tutor/helper
     asterism/*/tutor/protocol/*
     asterism/*/tutor/helper/meta
     asterism/*/tutor/helper/call/${node}
     ```
   - Ask (the calls, under the device's own name only):
     ```
     asterism/*/tutor/helper/meta
     asterism/*/tutor/helper/call/${node}
     ```
   - Watch: `asterism/**`
   - "Browsers have this role": off (the users' browsers get it one by one,
     section 9).
   A `**` does not match a chunk that starts with `@`, so each `@` line is
   needed as it is.
3. **The devices' rows** (e.g. `fmruby-aaaaaa`): Edit, tick `tutor` next to
   the roles they have. Only those devices reach the helper. For a user's
   browser (console 0.4.2 or later): section 9.
4. **Register**: kind `client`, name `tutor`, role `tutor-host`. Open it,
   "Issue a certificate", "Save all (.tar)": `tutor.tar`.
5. Apply (the banner "Review and apply").

## 4. Get the files

Next to the console's checkout:

```
cd /srv/asterism
git clone <the asterism-tutor repository> asterism-tutor
cd asterism-tutor/deploy/vps
cp env.example .env && chmod 600 .env
install -m 600 -o 1000 -g 1000 ~/tutor.tar credentials/tutor.tar     # sudo if you are not uid 1000
```

Copy `tutor.tar` to the server as you would a private key (scp, then remove
the copy in your downloads). `credentials/` is never committed (its
`.gitignore`).

`.env` (env.example says what each line is):

- `ASTERISM_PROJECT=asterism` (the console's project).
- `ASTERISM_TUTOR_CREDENTIALS=/credentials/tutor.tar`. The router is
  `tls/zenohd:7448` on the console's network (`TUTOR_ROUTER` changes it),
  not the public name in the `.tar`.
- `ASTERISM_TUTOR_DEVICES=fmruby-aaaaaa,...`: the same devices that have
  the role `tutor`. The role decides who reaches the helper; this list is
  the gem's own check on top (a device with the role but not in the list
  is told it is not registered).
- `ASTERISM_TUTOR_LLM=anthropic` and `ANTHROPIC_API_KEY=...` (or
  `ASTERISM_TUTOR_LLM=fake` to try the setup with canned answers first).
- The model and the limits: `ASTERISM_TUTOR_MODEL` (default
  `claude-haiku-5-5`), `ASTERISM_TUTOR_PER_DAY` (50 requests a device a
  day), `ASTERISM_TUTOR_COST_PER_DAY` (1.0 USD a day in all).
- `TUTOR_TZ` (default `Asia/Tokyo`): the day of the limits and of the
  records' files is this time zone's date, so a new day starts at 00:00 in
  Japan. It becomes the container's `TZ` (a `TZ` line in `.env` is not used).
- A request that fails only because the tutor stopped (an update, a
  restart; the device reads "stopped") is not counted in the device's
  requests of the day; what the LLM already cost for it is counted.
- `ASTERISM_TUTOR_MAKE=false` / `ASTERISM_TUTOR_FIX=false` turn "make" and
  "fix it for me" off.

## 5. Pull and start

The image is published for each version on the GitHub Container Registry
(`ghcr.io/ruby-asterism/asterism-tutor:<version>`, also `:<major>.<minor>`
and `:latest`; amd64), built by the repository's CI from the tag
`v<version>`. It holds the gem with its knowledge bundle and rules.

```
./update.sh 0.2.0         # checks out v0.2.0, pulls its image and starts it
```

By hand, the same is `git checkout v0.2.0`, `TUTOR_VERSION=0.2.0` in
`.env`, then `docker compose pull && docker compose up -d`.

### Building the image yourself

```
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose up -d
```

Give it a name of your own in `.env` first (`TUTOR_IMAGE=asterism-tutor-local`),
so a later pull does not replace it. `./update.sh --build 0.2.0` does the
same from the version's tag.

## 6. Check

```
docker compose ps                                   # tutor: running (healthy)
docker compose exec tutor bundle exec exe/asterism-tutor status
      # asterism-tutor 0.2.0 tutor/tutor/helper: up, joined to tls/zenohd:7448 (... 0 working, today 0 requests, $0.0000)
docker compose logs --tail 5 tutor
      # asterism-tutor 0.2.0: tutor/tutor/helper on tls/zenohd:7448 (llm: anthropic)
      # asterism-tutor: model claude-haiku-5-5, 50 requests a device a day, $1.0 a day in all
```

Then, on a device with the role: open AI Helper. It says
"つながりました (AI helper)。今日 0 / 50 回。" and answers a question. A
device without the role does not find the helper; a device with the role
that is not in `ASTERISM_TUTOR_DEVICES` is told it is not registered.

`status` exits 0 when the tutor is joined to the router with the helper
exposed, 1 when not (the router is away: "the router is away, joining it
again"; or it is stopping), 2 when the tutor has written no status for 15
seconds. The healthcheck runs it every 30 s: three failures in a row make
the container unhealthy. It joins the router again by itself when the
router comes back.

## 7. Updating and going back

```
./update.sh 0.2.1                 # the new version
./update.sh --when-idle 0.2.1     # restart only once no request is being worked on
./update.sh 0.2.0                 # back to the version before (its image is kept)
```

A restart (an update, `docker compose restart`, the server's reboot) does
not lose the records, the results the devices have not fetched yet or the
day's counts and cost (the volume). A request being worked on at the
moment gets 8 seconds (`ASTERISM_TUTOR_STOP_GRACE`) to end; after that it
fails as "stopped" and the device shows "AI の係が止まったので、答えを作れません
でした。もう一度送ってください。" when it asks again; it is not counted in
the device's requests of the day. A new request during the stop is told the
helper is stopping. The conversation so far (the last few
exchanges, forgotten after 30 minutes anyway) is not kept.

A new certificate for the row `tutor`: put the new `.tar` in place and
`docker compose restart tutor`.

## 8. Reading the records

One JSON object per line, one file a day (`tutor-YYYY-MM-DD.jsonl`), in the
volume's `log/`:

```
docker compose exec tutor ls /state/log
docker compose exec tutor cat /state/log/tutor-2026-11-19.jsonl | tail -n 20    # the date is TUTOR_TZ's
docker compose exec tutor sh -c 'grep "\"ev\":\"llm\"" /state/log/*.jsonl' | wc -l    # the LLM calls
```

`ev` is `start`, `hello`, `ask` (the request and the document sent), `llm`
(the prompt, the answer, the usage and `cost_usd`), `check`, `result`,
`failed`, `refused` (a device not registered, a limit, a mode turned off,
the stop), `cancel`, `rebase`, `new_talk`, `stop`. The gem never deletes
them; the console's backup does not take them. To keep a copy elsewhere:
`docker compose cp tutor:/state/log ./tutor-log`.

## 9. Browsers

The browser build (Family mruby in a web page, opened from the console)
can use the helper too, for the users you name. It needs **console 0.4.2
or later**: the role is given per user there, and the router gives it only
to the page the console's door connects with that user's certificate
(`wasm-<handle>`).

1. **In the console** (Admin > Members > Browsers): the user has a handle
   and a certificate ("in the ACL"; "Make the missing certificates" and
   Apply otherwise). Edit the user, tick `tutor` under "Roles of this
   browser", Save, Apply.
2. **In `.env`**: add the user's browser node to the devices,
   `ASTERISM_TUTOR_DEVICES=fmruby-aaaaaa,wasm-<handle>`, then
   `docker compose up -d`.
3. The user opens the browser build from the console ("Launch Web
   Studio" or a pass's link) and starts AI Helper.

Leave "Browsers have this role" off on the role `tutor`: with it, every
browser page would get the role, the pages that come through the shared
connection too, and those can call under any browser's name. Only the
user's own page reaches the helper: a second page of the same user opened
later takes the name over, and the earlier one goes on through the shared
connection without the role (the console's docs/g1_5.md, "Browsers the
router tells apart"). Another user's browser, and any page without the
user's certificate, does not find the helper.

With a console before 0.4.2 the role can only be given to every browser
at once; do not use it for the helper there.

## 10. Memory

Measured with the fake LLM: 55 MB RSS idle, 63 MB after requests with a
45 KB document. Loading the Anthropic SDK (the first real request) adds
about 48 MB. The healthcheck's command takes about 33 MB while it runs (a
second or so every 30 s). The container's limit is `TUTOR_MEM_LIMIT`
(256 MB); over it, the kernel stops the process and docker starts it again
(a request being worked on then fails as "stopped" at the next start).

## 11. Removing

```
docker compose down                 # the container; the volume asterism-tutor_state (the records) stays
```

In the console: disable or remove the row `tutor` and untick `tutor` on the
devices' rows, then Apply.
