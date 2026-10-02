# claude-multi-account

Run multiple Claude Desktop accounts side by side on one Mac, and keep your Claude Code session history identical in every one of them.

macOS · Bash + Python 3 (stdlib only) · MIT · unofficial, not affiliated with Anthropic

---

## The problem

Claude Desktop is built around one signed-in account at a time.

- **One account per app.** There is no "add account" and no profile switcher. Work and personal live in the same window, one at a time.
- **Switching accounts clears the OAuth cache.** Every switch is a fresh sign-in, in the browser, again.
- **The session list is stored per account.** Claude Code session records live in a folder keyed by account UUID. Switch accounts and the sidebar looks empty — not because the work is gone, but because the *index* for that account does not know about it.

The conversations themselves were never lost. The transcripts sit in `~/.claude/projects/` the whole time, shared by every account. Only the small per-account index files disagree about what exists.

## What this does

**1. Several Claude Desktop instances at once.** Each profile gets its own Electron user-data directory, so each one holds its own login, cookies and app settings, and they run at the same time in separate windows. One Claude.app install, no patching, no copies.

**2. One session list everywhere.** A small sync engine merges the per-account session records across every account and profile, newest wins, in every direction. It only ever adds a record to a store that lacks it or replaces an older copy; removing a session everywhere is a separate, opt-in flag. Optionally on a background job: once a minute, at load, and again whenever you switch accounts. Your sidebar looks the same no matter which account you are in.

What stays shared automatically, because it never was per-account: `~/.claude` — conversation transcripts, memory, skills, agents, `CLAUDE.md`.

## Quick start

```bash
git clone https://github.com/EminBudak/claude-multi-account.git
cd claude-multi-account
./install.sh

claude-multi doctor
claude-multi setup work@example.com personal@example.com
```

`install.sh` symlinks both commands into `/usr/local/bin` when that directory exists and is writable by you, and into `~/.local/bin` (created if needed) otherwise. It refuses to continue when no working `python3` is on your `PATH`, and prints the exact `PATH` line for your shell if the link directory is not already on it. `--force` replaces something unrelated already sitting at one of those names, `--uninstall` removes only the symlinks that point back into this checkout, and `--help` (or `-h`) prints its own usage. Nothing is copied, so `git pull` updates the installed commands in place; the installer never calls `sudo`, never installs the background job and never launches Claude.

`doctor` checks your environment before anything is created. `setup` creates the profiles and launchers, walks you through the sign-in order that actually works (see [the one-time sign-in step](#the-one-time-sign-in-step)), syncs the session lists once, installs the background job if it is not installed yet, and opens every profile.

> **`setup` quits every open Claude Desktop window before it starts, and again between accounts.** Anything running in the app — including an in-flight Claude Code session — is interrupted, so save first. A window that does not quit within 20 seconds gets `SIGTERM` and then `SIGKILL`. You get one confirmation prompt (you have to type `yes`) before any of this happens, and `setup` needs a real terminal: it exits with an error when stdin and stdout are not a TTY. It also refuses to start from *any* Claude Code session — it checks the `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` environment variables — and from any process whose ancestor is Claude Desktop. Run it yourself in Terminal.app from a plain shell; `--allow-inside-claude` overrides the check if you are certain your shell survives the quits.

Nothing is uploaded, nothing inside `Claude.app` is modified, the sync defaults to a dry run — and even `--apply` cannot remove a session record unless you add `--propagate-deletions`.

## Set it up with an AI coding agent

Most of this repository is safe to hand to Claude Code, Cursor or a similar agent. What an agent can do end to end:

- clone the repository and run `./install.sh`
- run `claude-multi doctor` and act on the output (no working `python3`, an unwritable launcher directory, the sync engine not found next to the CLI, launchers that are missing, stale (the checkout moved, or an older version wrote them), or unsigned, profile directories that are not `0700`, and which deletion mode the installed background job runs in)
- run the dry run, `claude-sessions-sync`, read the plan, then `claude-sessions-sync --apply` — merge-only, and unable to remove a record or marker without `--propagate-deletions`
- install or remove the background job and inspect `claude-sessions-sync --status`, `--restore-list`, `~/.claude/logs/claude-sessions-sync.log` and `~/.claude/logs/claude-sessions-sync.err.log`
- create a profile and its launcher with `claude-multi work@example.com -y`, and list the result with `claude-multi list` — but only while no other Claude instance is running, or with a human at the screen (see the `-y` point below). An agent hosted in Claude Desktop always has one running.

Three things an agent has to get right:

- **Option order.** Options are parsed by the subcommand, not by the dispatcher, so they come *after* the subcommand word — and in the bare form the address *is* that word: `claude-multi work@example.com -y`, `claude-multi open -y <name>` or `claude-multi open <name> -y`. `claude-multi -y work@example.com` is rejected with `unknown option: -y`.
- **`-y` is not optional for an unattended run, and not always enough.** Without it, creating a profile asks for confirmation; with no terminal to ask on, it falls back to a macOS dialog whose default button is Cancel and which counts as “no” after 120 seconds. `-y` answers only that question. A profile that is not signed in yet, opened while any other Claude instance is running, also gets the sign-in warning (see [the one-time sign-in step](#the-one-time-sign-in-step)) — with no terminal, another such dialog — and nothing is created unless someone answers it. Opening a profile that is already running shows the restart question the same way. Declining to create a profile exits 1, and so does declining the sign-in warning; a dialog that could not be shown at all exits 2, after a notification and a line on stderr. Declining to *restart* a profile that is already running exits 0 — it was brought to the front, so the open itself was done.
- **It does not wait on the app, from any directory.** Every instance is started through LaunchServices (`open -n`), exactly as the Dock does: detached, in a process group of its own, with `/` as its working directory and no inherited stdin. So a tool call that runs `claude-multi <email>` gets its exit status as soon as the instance is started — after any dialog above has been answered or has timed out, and after the pre-open sync (see `claude-multi <email>` in the [command reference](#command-reference); 25 seconds at most) — instead of waiting on the app; the app's MCP servers do not inherit the agent's working directory; and stopping the agent's shell or task never takes a Claude instance down with it (see [Troubleshooting](#troubleshooting)).

What an agent categorically cannot do:

- **The sign-in itself.** It happens in your system browser, against your real credentials, and comes back through the `claude://` URL scheme into the Claude window. A human has to do it, once per profile. No flag skips it.
- **`claude-multi setup`.** That command force-quits every Claude Desktop window, which would kill the Claude Code session hosting the agent mid-run. It refuses inside any Claude Code session and inside anything Claude Desktop started, and it needs a TTY besides. (`--allow-inside-claude` exists; an agent should not reach for it.) Run `setup` yourself in **Terminal.app**, and leave the agent the parts above.

A reasonable division of labour: let the agent install, run `doctor`, and do the syncing and status work; you run `setup` in a terminal and sign each account in.

## How it works

```
        /Applications/Claude.app         one install, ~900 MB, never modified
            ^          ^          ^
            |          |          |      a launcher is ~1 MB and does one thing:
       (default)   launcher   launcher   run `claude-multi open <email>`, which
            |          |          |      runs the real app with --user-data-dir
            |          |          +---------------------------+
            |          +-------------+                        |
            |                        |                        |
  ~/Library/Application       ~/.claude-profiles/      ~/.claude-profiles/
    Support/Claude              work@example.com        personal@example.com
  --------------------        -------------------      --------------------
   login + cookies             login + cookies          login + cookies
   app settings                app settings             app settings
   session records             session records          session records
            \                          |                        /
             \                         |                       /
              +--------->  claude-sessions-sync  <------------+
                       merges session records, newest wins,
                       every store, in both directions --
                       adds and updates only, unless you
                       pass --propagate-deletions

  ~/.claude/                  shared by every profile; the sync only adds
    |                         logs/ and backups/ of its own
    projects/**/*.jsonl         conversation transcripts  <-- not read, not written
    CLAUDE.md, skills/, agents/, memory
```

**Isolation** comes from Electron's documented `--user-data-dir` flag: each profile is launched as `Claude --user-data-dir=~/.claude-profiles/<email>`, and the instances coexist because the app holds no single-instance lock. Every place the tool starts an instance — `claude-multi <email>`, `open --restart`, and both launches in `setup` — goes through one function that asks LaunchServices to start it (`open -n -a Claude.app --args --user-data-dir=…`), the way the Dock or Finder would: parent `launchd`, a process group of its own, `/` as its working directory, no inherited stdin. Whatever directory you ran the command in never reaches the app or the MCP servers it spawns.

**The launchers are not copies of the app, and not shortcuts to it either.** Each generated `.app` stub looks for `claude-multi` in `/usr/local/bin`, `~/.local/bin`, `~/bin`, `/opt/homebrew/bin` and finally the checkout it was generated from, and execs the first one it finds as `claude-multi open <name>` — with `open`, because only an address-shaped name works without it. So a launcher depends on the CLI staying reachable: it shows a dialog saying so when the checkout it was generated from has been moved or deleted and no installed `claude-multi` is left in those directories (re-run `./install.sh` from the new place). Removing only the symlinks with `./install.sh --uninstall` does not break it while the checkout stays where it was. Every bundle is **ad-hoc signed** (`codesign --force --deep --sign -`) as the last step of generating it, because Gatekeeper re-evaluates an *unsigned* bundle on every single launch — measured at roughly 1.7 s from double-click to first process unsigned, against roughly 0.5 s once signed. Signing is best effort: `codesign` ships with the Command Line Tools, and a launcher still works, just slowly, without it. `claude-multi app <email>` always regenerates and re-signs one; opening a profile only refreshes a launcher that is *missing or stale* (written by a different copy or an older version of the CLI), so an unsigned but otherwise current launcher is reported by `doctor` rather than silently replaced.

**The sync** writes session *record* files and, only when you run it with `--propagate-deletions` or `--restore`, deletion-marker files — plus its own log, error log, lock and backups under `~/.claude/`, and the LaunchAgents plist when you run `--install`. The records are:

```
~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json
~/.claude-profiles/<email>/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json
```

It reads three more files that it never modifies. `~/.claude-profiles/accounts.tsv`, which it consults only to recognise a profile directory that `claude-multi` manages. And two that together tell it which store the *main* app is using right now, so that a main app freshly signed in to an account with an empty store still gets populated (a store that holds records is found by listing anyway): `~/Library/Application Support/Claude/config.json`, of which it uses one field, the account the main app is signed in to, and the desktop app's own log `~/Library/Logs/Claude/main.log` (only the final 256 KB), for that account's most recent initialization line, which names the org. The log is shared by every instance, including the ones started with `--user-data-dir`, so lines for any other account are never the candidate — otherwise a profile's line could be mistaken for the main app's and an unused folder filled with copies. And during an account switch the app briefly logs a pairing of account and org that it does not keep, a couple of seconds before the line for the pair it settles on — while the background job, triggered by that very switch, may already be running. So the candidate line is trusted only when its own time stamp shows it is at least 10 seconds old (a stamp that cannot be read, or lies in the future, is not trusted) **and** no later line for a different account names the same org. When either check fails, or there is no readable account or no line for it, no store is guessed: a later run decides, which costs a fresh empty store nothing but a short delay. One case is left: a pairing the app logged and then abandoned — an account switch that never completed — that stays the newest line for that account for more than 10 seconds, with nothing later claiming its org, reads exactly like a finished sign-in and is adopted. The cost is an unused folder holding copies of the index records; no account reads it and nothing is lost. Both files are opened without blocking and used only when what was opened is a regular file (a symlink to one is followed — they are only ever read), so a fifo or anything else at either path is skipped instead of stalling the run; a `config.json` larger than 4 MB is not read at all. The same `config.json` is also registered with launchd as the background job's change trigger, because the app rewrites it on an account switch. `claude-multi` reads each profile's own `config.json` to show the signed-in account in `list`.

These records are tiny index entries, and they carry no account or org field — which is why they are portable between stores verbatim. For each session id the engine picks the copy with the newest `lastActivityAt` and writes it to every store that is missing it or has an older one; the session id is the record's *file name*, so a file whose inner `sessionId` contradicts its own name is never used as a source, and never overwritten or removed as a destination — it may be the only copy of that other session. (One limit, on the default case-insensitive volume: two record names that differ only in letter case are the same file there, so a file stored under one spelling can be reached, and replaced by a newer copy, through the other. Claude Desktop writes session ids in lower case and never produces such a pair; it takes hand-made file names.) A `lastActivityAt` that is not a plausible millisecond value — before 2001, or more than a day ahead of this Mac's clock — never wins, and a copy carrying one is never overwritten. Writes are atomic (hidden temp file plus rename, with the destination and its marker checked once more just before the rename), record files are always written as UTF-8 whatever the locale, and an advisory `flock(2)` prevents overlapping runs. `bridgeSessionIds` (Remote Control identity, which belongs to the source account's cloud) is dropped when copying; if the target already has its own value, that value is kept. Anything that cannot be read — a record caught mid-write, a record holding a number that is not finite (`NaN`, `Infinity`, or a literal such as `1e999` that overflows to one: the app never writes those, and a copy of it would not be JSON the app can parse), a truncated marker, a `deleted_<uuid>` entry that is not a plain file (a directory, a symlink, a fifo), a destination that changed between plan and apply — is left alone for that run and reported, never guessed at. Index files are only ever opened as regular files: a symlink is not followed and a fifo cannot stall the run.

A parked copy of a profile, an account folder or an org folder (`personal.bak-20260101/`, `work@example.com copy 2`, or a plain trailing `.bak`) is skipped entirely — a word like `archive` that is only a label of the address's domain (`me@mail.archive.example`) does not count — and so are the app's own `local_<id>.bak.json` snapshots next to the live records. A directory under `~/.claude-profiles/` counts as a live store only when it really is an app profile directory (it has its own `config.json`) and is either listed in `accounts.tsv` or the app itself has written one of its own files there within the last 30 days — `config.json`, `Local State`, `Preferences` and the rest of the Electron state at the top of the profile directory, never the session store this tool writes into, so the sync's own writes cannot keep an abandoned copy alive. Anything else is treated as a frozen snapshot — not read, not written, its markers ignored — and the run names it once, with the remedy. `accounts.tsv` is refreshed only by `claude-multi list` (and by `setup`, which ends by running it), which registers every profile whose name is an e-mail address and which is signed in; opening a profile does not write it. So if a profile you still use is skipped as idle, run `claude-multi list` once, or just open it — once the app has written its own files there, the next sync takes it back in. (The sync `claude-multi` runs right before opening it is too early for that, so the window that first open shows still has the old list; restart it once after that next sync.)

**Deletions do not propagate unless you ask for them.** Deleting a session in the app leaves a marker file (`deleted_<uuid>`) holding a millisecond timestamp. By default the sync **never removes a record or a marker**: it does not unlink a record, it does not write or copy a marker, and it does not clear a stale one. A default run only adds a record to a store that lacks it, or replaces a strictly older copy. Every serious bug ever found in this tool has been in the deletion path, so the mode that cannot lose anything is the one you get without asking.

A default run still *honours* each store's own marker. Because it may not clear a marker either, it writes no record at all into a store that holds **any** marker for that session, stale or not: a record sitting next to a marker is the pair that can hide a session, and no later default run could repair it. So a session you delete in one account stays gone there and survives in the others, and this mode never creates that pair itself — a pair already on disk is left exactly as it is. A `deleted_<uuid>` entry that is not a plain file counts as a marker here too: nothing is written next to it. (The one thing a default applying run does remove is this tool's own temp file — one left behind by a run that was killed mid-write, or the one it has just written when a last check before the rename says the write must not happen — named exactly `.sync-<pid>-local_<id>.json.tmp`, neither a record nor a marker. Nothing else is swept, whatever its name.)

`--propagate-deletions` opts into delete-everywhere. A session then counts as deliberately deleted when a marker really exists **and** its timestamp is at least as new as the winning record's `lastActivityAt`: the record is removed from every store and the marker is copied there. A marker *older* than the record is stale — the session was used again after being deleted — so it is never propagated, and a stale marker found next to a live record is cleared instead, because the app does not produce that combination itself and it can hide a live session. A marker is only ever copied into other stores when **no** store still holds a file for that session: a file that exists but could not be interpreted (unparseable, a name that is not a plain `local_<id>`, a body naming a different session) blocks propagation, because writing a marker next to a living record is precisely what hides it. A copy with no `lastActivityAt` at all, or whose `sessionId` names a different session, is never removed, and no marker is written next to it. Removing a record, propagating a marker and clearing a stale one all count as destructive, so each is backed up first. Stale markers are cleared *before* any record is written, and when that backup fails the whole destructive part is cancelled together with every write into a store that still holds a marker for that session — so this mode never leaves a record next to a marker either, not even after a crash half way through.

`--no-delete` is still accepted as a **deprecated no-op** — it now describes the default — and it wins if you pass both: `--no-delete --propagate-deletions` prints a note and deletes nothing.

**Timing.** Claude Desktop reads the session list at startup and on account switch only — it does not watch the directory. So synced sessions show up after a restart or an account switch, not live in a window that is already open.

## Command reference

### `claude-multi` — profiles and launchers

| Command | What it does |
| --- | --- |
| `claude-multi <email>` | Open that profile. Creates the profile and its launcher on first use, after asking. If that profile is already running, its instance is brought to the front and you are offered a restart — closing a Claude window does not quit the instance, so a profile can be running with nothing on screen; declining leaves it running and exits 0. If the background sync job is installed **and loaded** (`launchctl` knows it), and the profile already existed, one sync runs right before the instance starts — merge-only, it never deletes, whatever mode the installed job runs in — so the profile opens on the current list. That can add a short delay: it waits up to 20 seconds for a sync that is already running, and is given 25 seconds in all, after which the profile opens anyway and the sync finishes on its own; on a terminal it prints one line first. Without the job, opening a profile does not sync. It does not help a profile the sync currently skips as idle (see above): that one is taken back in only by a sync that runs after the app has written to it, and shows the list from the start after that. The instance is started through LaunchServices, detached from your shell. Only an address-shaped word (`something@something.something`) is accepted here. |
| `claude-multi open <name>` | The same, for a profile name that is not an e-mail address — the only way to reach one. |
| `claude-multi list` | Table of every profile: name, running or not, which account is signed in, session count. Also refreshes `accounts.tsv` from the profile names — it and `setup`, which ends by running it, are the only commands that write it — which is what tells the sync that a profile is live however long it has been idle. |
| `claude-multi setup [email...]` | Guided first-time setup, after one typed `yes`: creates the profiles and launchers, **quits every Claude Desktop window** (and again between accounts), signs each account in alone, syncs the session lists once (waiting up to 20 seconds if the background job is mid-run), installs the background job at a one-minute interval *if it is not installed already* — both in the default merge-only mode — and opens every profile. Asks for the addresses interactively when none are given. Exits non-zero when at least one account was skipped. |
| `claude-multi app <email>` | (Re)generate that profile's launcher app only, and re-register it with LaunchServices. Works before the profile exists. |
| `claude-multi remove <email>` | Delete a profile directory and its launcher, after you type `yes`. Refuses while that instance is running, and refuses outright without a terminal. |
| `claude-multi sync [args...]` | Forward everything to `claude-sessions-sync` (e.g. `claude-multi sync --status`). |
| `claude-multi doctor` | Environment check: Claude.app, python3, launcher directory, profile root, sync engine, the background job and which deletion mode it is installed with, profiles, profile permissions, launchers (missing, stale, or unsigned and therefore slow to launch), and the working directory of every running instance — any that is not `/` is named, with the fix (read with `lsof`; see [Troubleshooting](#troubleshooting)). Exits non-zero if any check FAILs. |
| `claude-multi selftest` | Internal checks: every helper that answers *which process / which account / how many sessions* must report nothing as empty output and exit 0, and every AppleScript the tool runs must compile — the confirmation dialog, the window raise, the quit, the notification and the launcher stub's dialog. Each is defined once and compiled exactly as it runs. It launches nothing, reads no transcript and writes nothing. |
| `claude-multi help` | Usage. Also printed by `claude-multi` with no arguments, `-h` or `--help`. |

**Options.** They are parsed by the subcommand, so they come *after* the subcommand word, before or after the profile name (`claude-multi open -y <name>`, `claude-multi setup --no-mcp-config work@example.com`). In the bare form the address *is* that word, so there they must follow it (`claude-multi work@example.com -y`); put one before it and you get `unknown option`.

| Option | Where | What it does |
| --- | --- | --- |
| `-y`, `--yes` | `<email>` / `open` | Do not ask before creating the profile. |
| `--restart` | `<email>` / `open` | Quit this profile's running instance first, then open it again — for when the profile is running with no window on screen. Skips the question you are otherwise asked. Opens the profile normally when it is not running. |
| `--with-mcp-config` | `<email>` / `open` / `setup` | Copy `claude_desktop_config.json` from the main profile into a new profile. |
| `--no-mcp-config` | `<email>` / `open` / `setup` | Do not copy it, and do not ask. |
| `--allow-inside-claude` | `setup` | Run even though this looks like a shell hosted by, or started by, Claude Desktop. |

`list`, `app`, `remove`, `doctor` and `selftest` are also accepted with a `--` prefix (`claude-multi --doctor`). An unrecognised first word is an error rather than a new profile — only an address-shaped name opens or creates one without `open`.

Use the full email address as the profile name. It is what `list` shows, and it is how you tell two windows apart three weeks from now. On the default, case-insensitive macOS volume a name that differs from an existing profile only in letter case *is* that profile: every command switches to the spelling the profile directory already has, so the running checks, the launcher and the directory agree.

**Environment.** `CLAUDE_MULTI_LAUNCHER_DIR` overrides where launcher bundles are written. Launcher names contain the account address and are visible to anyone who can browse that folder or your Spotlight results, so set it to `~/Applications` on a shared or regularly screen-shared Mac. Unset, the tool uses `/Applications` when it is writable and `~/Applications` otherwise.

### `claude-sessions-sync` — the session list

| Command | What it does |
| --- | --- |
| `claude-sessions-sync` | Dry run. Prints the deletion mode it would run in, every store with its record count, marks the one the app is using now, and lists the counts plus the first 15 records it would write and the first 10 it would remove. Writes no session data. |
| `claude-sessions-sync --apply` | Synchronize now: add missing records, replace strictly older copies, and nothing else. In this default mode no record or marker is ever unlinked; the only files it removes are its own temp files. |
| `claude-sessions-sync --apply --quiet` | Log only when something changed. This is what the background job runs. |
| `claude-sessions-sync --apply --propagate-deletions` | Opt in to delete-everywhere: remove a record whose marker is at least as new as the winning copy from every store, copy that marker into every store, and clear stale markers next to live records — before writing any record. Backed up first; if that backup fails or does not cover every file at risk, the deletions are cancelled for that run and only the writes go ahead, minus any write into a store that still holds a marker for that session. |
| `claude-sessions-sync --no-delete` | Deprecated no-op, kept so jobs installed by an older version keep working: it is the default now. It wins over `--propagate-deletions` when both are given. |
| `claude-sessions-sync --install [--every 1m]` | Install or replace the background job. Default interval one minute, floor ten seconds (launchd throttles below that, and a shorter value is raised to ten with a warning); it also runs at load and whenever the app rewrites `config.json`, i.e. on every account switch. The job runs `--apply --quiet` in the default merge-only mode; add `--propagate-deletions` here to bake delete-everywhere into it. |
| `claude-sessions-sync --uninstall` | Remove the background job and its plist. |
| `claude-sessions-sync --status` | Interval and deletion mode read back out of the installed plist, launchd run count and last exit code, backup count, the error log if it is non-empty, and the last 8 log lines. |
| `claude-sessions-sync --wait <seconds>` | On any run that takes the lock — the dry run, `--apply`, `--restore` — if another sync is already running, wait up to this long for it instead of giving up at once (default 0, capped at 300). `--status`, `--install`, `--uninstall` and `--restore-list` ignore it. `claude-multi` passes `--wait 20` when it syncs right before opening a profile and in `setup`. |
| `claude-sessions-sync --restore-list` | List the automatic backups: timestamp, records, markers, stores. |
| `claude-sessions-sync --restore <timestamp>` | Copy a backup's index files — records **and** deletion markers — back into the matching stores. It is a rollback: a record that is newer on disk than in the backup is replaced by the backup's older copy, and before copying anything it prints how many records that is and names the first five. The markers belonging to the sessions it revives are skipped and then cleared in every store, so the next sync cannot immediately undo it; a backed-up marker is also left out of any store that now holds a live record for that session, and nothing is written into or through an entry that is not a plain file. The current state of every store it writes into or clears a marker in is backed up first — a profile store the sync currently skips included — and the restore does not start at all if that backup cannot be written or lacks a file the restore would overwrite or clear. A store that cannot be listed is left alone, and a profile that no longer exists (after `claude-multi remove`) is not recreated. Nothing the backup does not know about is removed. |

Durations for `--every` (which is also spelled `--interval`): `s`/`m`/`h`/`d`, case-insensitive, combinable — `20s`, `1m`, `1m30s`, `2h`, `30d`, or a bare number of seconds. `m` means minutes. `--every` without `--install` is ignored with a note.

### Files it uses

| Path | What |
| --- | --- |
| `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json` | A session index record — the only file the sync copies. Same layout inside every profile directory |
| `…/<accountUuid>/<orgUuid>/deleted_<uuid>` | A deletion marker holding a millisecond timestamp, written by the app. Always read; written, copied or cleared by a sync run only with `--propagate-deletions`, and by `--restore`, which puts a backup's markers back and clears those of the sessions it revives. An entry under this name that is not a plain file is never touched, and the session is left alone |
| `~/.claude-profiles/<email>` | Profile data directory, one per account (created `0700`, readable only by you) |
| `~/.claude-profiles/accounts.tsv` | `uuid<TAB>email` map, learned from profile names when you run `list` or `setup` (which ends by running `list`) — and only then; opening a profile does not write it (created `0600`; delete it to reset the labels). The sync reads it too, only to tell a live profile directory from a parked one |
| `/Applications/Claude - <email>.app` | Launcher bundle (`~/Applications` when `/Applications` is not writable, or wherever `CLAUDE_MULTI_LAUNCHER_DIR` points) |
| `~/.claude/logs/claude-sessions-sync.log` | Sync log, trimmed to the last 400 lines once it passes 800 |
| `~/.claude/logs/claude-sessions-sync.err.log` | Anything the background job writes to stderr. launchd owns this file (`StandardErrorPath`); the tool only caps it, keeping the last 128 KB once it passes 256 KB |
| `~/.claude/logs/claude-sessions-sync.lock` | Run lock, created on the first run (a dry run included) and then held with `flock(2)`. The file itself is never deleted — the lock is the open descriptor, which the kernel releases however the run ends, so a leftover file is not a stuck run. `--status`, `--restore-list`, `--install` and `--uninstall` do not take it. |
| `~/.claude/backups/claude-sessions-<YYYYmmdd-HHMMSS>/` | Automatic backups of session index files — records and deletion markers only, never a transcript. Two runs in the same second get a `-2` suffix. A backup is assembled in a `.partial` directory and renamed into place only once it is complete, so a half-written one is never listed, restored from, or counted as "this machine has backups" |
| `~/Library/Logs/Claude/main.log` | The desktop app's own log — **read only**, last 256 KB, to find the main app's active store (only the newest line for the main app's own account counts, and only once it is at least 10 seconds old and no later line for another account names its org) |
| `~/Library/Application Support/Claude/config.json` | **Read only**, one field: the account the main app is signed in to. Also registered as the background job's change trigger. Never modified. |
| `~/Library/LaunchAgents/io.github.claude-multi.sync.plist` | The background job, written by `--install` |
| `io.github.claude-multi.sync` | launchd label of that job |
| `io.github.claude-multi.profile.<slug>` | Bundle identifier of a generated launcher |

**Backup retention** is not a plain count. The newest 7 are kept, but nothing younger than 24 hours is pruned, and of the backups taken before a destructive run (or before a `--restore`, whose safety backup counts the same way) the **newest 3** are never pruned, and neither is the very first one. The newest ones are the copies you actually reach for — a wrongly hidden session is noticed days after the run that hid it, not months — and the first is the state before this tool ever deleted anything. A pure count would not do: a destructive plan that keeps failing is re-planned every minute, and those retries would evict the only copy of what was deleted. Above 28 backups the age floor gives way and the oldest are pruned anyway, except for those (at most 4) protected pre-deletion ones. For the same reason a backup less than 24 hours old is reused as this run's safety net instead of a new one being written — provided it holds every file the run could destroy and every index file in every store still matches it by **name, size and modification time**, which is what the fingerprint compares; it does not read file contents.

## The one-time sign-in step

Signing in opens your system browser and comes back through the `claude://` URL scheme. macOS hands that callback to the instance that registered the scheme — in practice, the app that was launched first. If another Claude window is open while you sign a *new* profile in, the callback lands in that other window and the new profile stays on the sign-in screen.

So, once per new profile:

1. Quit every Claude window.
2. `claude-multi <email>` — this instance must be the only one running.
3. Sign in, then **quit** that instance (Cmd+Q). Closing its window is not enough: Claude keeps running without a window, and the next profile's sign-in would go to it.
4. Repeat 2–3 for the next profile.
5. Open them all. From here on they run side by side, indefinitely.

The window you sign in with lists no sessions at first. Claude creates a profile's session store only at sign-in, and reads the list only when it starts, so the sync has nothing to write into until after that window is already up. That is why step 3 quits it: the next time the profile opens *after a sync has run*, the list is there. With the background job installed that happens by itself — `claude-multi <email>` syncs right before it starts the instance; without the job, run `claude-sessions-sync --apply` before reopening it. `claude-multi setup` handles all of this for you; if you sign in by hand and keep the window open, restart it once with `claude-multi open <email> --restart` (after `claude-sessions-sync --apply` if the job is not installed). `claude-multi` prints the variant that applies when it creates a profile.

Getting the order wrong is harmless — the sign-in simply does not complete, nothing breaks. Opening a profile that is not signed in yet while other instances are running prints this warning and asks before continuing, every time until that profile has an account. `claude-multi setup` does the quitting for you, waits up to five minutes per account for the sign-in, and offers retry / skip / abort if it times out.

## FAQ

**Will I lose sessions? Is this safe to run the first time?**

**No sync run in the default mode can remove a session record.** No run without `--propagate-deletions` unlinks a record, writes a deletion marker or clears one; a plain `--apply` only adds a record to a store that lacks it or replaces a strictly older copy, never into a store that holds a marker for that session. The only files such a run does remove are its own temp files (`.sync-<pid>-local_<id>.json.tmp`): a leftover from a run killed mid-write, or one it has just written and then, at a last check before the rename, decided not to use. `--restore` is a separate command and the deliberate exception: it is a rollback, so it copies the backup's records and markers back over what is there now, and it clears the deletion markers of the sessions it revives, because those markers would otherwise delete them again on the next run. On top of that:

- Conversation transcripts in `~/.claude/projects` are never read and never written — they are not account-scoped and were never the problem. Only the small per-account index files move.
- Running the command with no flags is a dry run: it prints what it would do and writes no session data.
- The first apply that has anything to write takes an automatic backup under `~/.claude/backups/`, and so does any run that would delete a record, propagate a marker or clear a stale one. A backup that fails, or that does not cover every file the run could destroy, cancels the destructive steps (any *other* file it cannot copy, such as one with no read permission, is left out with a warning) — writes still go ahead, because a write only ever replaces a record with a strictly newer copy that still exists in the store it came from, except a write into a store that still holds a marker for that session, which waits with them.
- Anything that cannot be read — a record caught mid-write, a truncated marker, a destination that changed between plan and apply — is left alone for that run and reported, never guessed at.
- If something does go wrong, `--restore-list` shows the backups and `--restore <timestamp>` puts one back, clearing the markers of the sessions it revives so the next sync cannot immediately undo it. It first tells you how many current records are newer than the backup's copy and will be rolled back, and it backs up the current state of every store it writes into so the restore itself can be undone.

The only sync run that removes a session record is one with `--propagate-deletions`, and even then only for a session you deleted yourself in the app, with the deletion at least as new as the record's own last activity. Outside the sync, `claude-multi remove <email>` deletes a whole profile directory, its session store included, after you type `yes`: records the sync had copied into other profiles survive there, but any it had not (a profile the sync skips, or sessions made since the last sync) go with it. The transcript stays on disk either way.

**Does it sync my conversations to the cloud, or to my other machine?**

No. Everything is local. Nothing is uploaded, no network calls, no account of ours, no telemetry. The tool rearranges files that are already on your disk, on that one Mac.

**Why don't new sessions appear immediately in an already-open window?**

Claude Desktop reads the session list at startup and on account switch, then keeps it in memory. It does not watch the folder. Restart the window, or switch accounts, and everything is there.

**Does it duplicate the ~900 MB Claude.app?**

No. There is one `Claude.app`, untouched. Each launcher is its own tiny `.app` bundle — about 1 MB, most of that the copied icon — that runs `claude-multi open <email>`, which in turn starts the real binary with that profile's `--user-data-dir`. That indirection is why a launcher stops working when the checkout it came from is moved or deleted and no installed `claude-multi` is left to find, and why `claude-multi app <email>` exists to regenerate one.

**Is this affiliated with Anthropic?**

No. Unofficial and unaffiliated. It uses a documented Electron command-line flag and local files in your home directory. Claude and Anthropic are trademarks of Anthropic.

**Does it need my password or tokens?**

No. It never asks for, copies, stores or transmits your Claude credentials. To learn which account is signed in, it reads one field (`lastKnownAccountUuid`) of the app's `config.json` — the main app's in the sync; the main app's and each profile's in `claude-multi`, for `list` and to tell whether a profile has signed in yet — and uses nothing else in that file. You sign in yourself, in the normal Claude sign-in window, exactly as you do today; the tool only decides which data directory that window uses. One related caveat: when a new profile is created you are *asked* whether to copy your existing MCP configuration into it. That file can contain your own third-party API keys, so it is opt-in and never copied silently — `--with-mcp-config` copies it, `--no-mcp-config` skips it, and with neither flag the question is asked on a terminal and defaults to no (with no terminal to ask on, it is not copied). Profiles are created `0700` and the account map `0600`, so other user accounts on the Mac cannot read them.

**What happens when Claude Desktop updates?**

It keeps working: nothing inside `Claude.app` is modified or patched, so an update replaces a file the tool does not depend on. If something stops working after an update, run `claude-multi doctor`, and `claude-multi app <email>` to regenerate a launcher. A future update could change the session-record format — see [Safety and limitations](#safety-and-limitations).

**How do I undo everything?**

```bash
claude-sessions-sync --uninstall              # remove the background job first
./install.sh --uninstall                      # remove the commands
rm -rf ~/.claude-profiles                     # profiles: logins, settings AND their session lists
rm -rf "/Applications/Claude - "*.app         # the launchers
rm -rf ~/Applications/"Claude - "*.app        # ...if /Applications was not writable
rm -rf "${CLAUDE_MULTI_LAUNCHER_DIR:?}/Claude - "*.app  # ...if you set CLAUDE_MULTI_LAUNCHER_DIR
rm -rf ~/.claude/backups/claude-sessions-*    # the automatic backups
rm -f  ~/.claude/logs/claude-sessions-sync.log
rm -f  ~/.claude/logs/claude-sessions-sync.err.log
rm -f  ~/.claude/logs/claude-sessions-sync.lock
```

`./install.sh --uninstall` prints the same list, with the full path to `claude-sessions-sync` since its symlink is gone by then.

Your conversation transcripts (`~/.claude/projects`) are untouched by all of it. One thing to know before the `rm -rf ~/.claude-profiles` line: each profile keeps its own copy of the session *list*. If the sync has been running, those entries also exist in your main Claude profile and nothing visible is lost. If a profile was never synced — the sync never ran, or it skipped that profile — its sidebar entries go with it (the transcripts stay on disk). Run `claude-sessions-sync --apply` once first if you are unsure. Claude Desktop then goes back to behaving exactly as it did before.

**Windows or Linux?**

macOS only today, and the README will say so until that changes. The session-record layout and the newest-wins merge are platform-independent; what is macOS-specific is the launcher (`.app` bundles, `lsregister`), the background job (`launchd`), the `claude://` callback behaviour, and the application-support paths. A port would need the equivalent per platform — Scheduled Tasks or a shortcut on Windows, systemd user timers and `.desktop` files on Linux. PRs welcome; please keep the sync engine shared and push platform code behind the same CLI.

## Requirements

- macOS. The tool drives Claude Desktop, Electron user-data directories and `launchd`; `install.sh` refuses to run anywhere else.
- Claude Desktop installed at `/Applications/Claude.app`. The installer only warns if it is missing or sits in `~/Applications`, but the launchers will not find it there.
- A working `python3`. `/usr/bin/python3` is preferred and is the interpreter the background job bakes into its plist, because it outlives Homebrew upgrades and Xcode being moved; on a stock Mac it is the Command Line Tools *stub*, which prompts to install the tools rather than running anything, and `xcode-select --install` turns it into a real interpreter. Any other working `python3` on your `PATH` is used as a fallback — `claude-multi` probes `/usr/bin/python3` first and then plain `python3`, `doctor` warns when it lands on the second, and `--install` says so too when it has to put a non-system interpreter in the plist. The sync engine is standard library only.
- An admin-group account if you want launchers in `/Applications`. No `sudo` is needed: `/Applications` is writable by admin users. Otherwise the tool falls back to `~/Applications`.
- A profile root without spaces. `~/.claude-profiles` is that by design — profile paths are read back out of `ps` output — and `doctor` fails if it ever contains one.
- One Claude account per profile, obviously — this does not multiply your subscription.

## Troubleshooting

**Sign-in lands in the wrong window.** Another instance was running and took the `claude://` callback. Quit every Claude window, open just the new profile, sign in there, then reopen the others. See [the one-time sign-in step](#the-one-time-sign-in-step).

**A new profile's sidebar is empty right after its first sign-in.** Expected, once per profile. The session store for an account does not exist until that account signs in, and Claude reads the list only at startup — so the window you signed in with started before there was anything to read. With the background job installed, `claude-multi open <email> --restart` syncs first and then starts the profile. Without it, run `claude-sessions-sync --apply` first, then the same `--restart`. From then on the profile opens on the full list.

**Sessions stopped reaching the other accounts, and the log has gone quiet.** Check `claude-sessions-sync --status`: if the job shows as running for minutes at a time, it is being I/O-throttled. Earlier versions installed the job as a low-priority background process, and under real load — a virtual machine, a browser and several Claude instances at once — macOS starves such a job's disk access until a run that takes seconds in the foreground never finishes. Current versions install it at standard priority. Re-run `claude-sessions-sync --install` (add `--every` and `--propagate-deletions` again if you used them) to rewrite the job.

**An MCP server fails in a profile with `EPERM` / `uv_cwd`.** The instance was started with a working directory inside a folder macOS protects with TCC — `~/Documents`, `~/Desktop`, `~/Downloads` — and every MCP server it spawns (`npx`, `node`, …) inherits it; node's `getcwd()` is refused there, so each one dies at startup. It happens when Claude is started from a shell sitting in such a folder: by an older version of `claude-multi`, or by running the Claude binary yourself. Current versions start every instance through LaunchServices, as the Dock does, so it always runs in `/`. `claude-multi doctor` names every running instance whose working directory is not `/` and prints the fix — for a profile, `claude-multi open <email> --restart`; for the main app, quit it and start it from the Dock or Finder. To check one yourself: `lsof -p <pid> -a -d cwd -Fn`.

**A profile window disappeared when I closed a terminal (or an agent stopped a task).** Older versions started profiles from the shell that ran the command, so the instance stayed in that shell's process group; ending the shell's job — closing the tab, or an agent harness killing a background task — killed Claude too (`nohup` only protects against the hang-up signal). Current versions start every instance through LaunchServices in a process group of its own, like the Dock. Re-open the profile with `claude-multi <email>`; `ps -o pid,ppid,pgid -p <pid>` should show parent `1` and a process group equal to its own pid.

**The launcher is not in Finder / Spotlight.** Finder caches the Applications folder view; close the window and reopen it. `claude-multi app <email>` regenerates the bundle and re-registers it with LaunchServices, which is what puts it in Spotlight.

**A launcher takes a second or two to open.** Two things add up here. First, with the background job installed, every open — from a launcher or from the terminal — runs one merge-only sync before it starts the instance, and waits up to 20 seconds when the background job is mid-run (25 seconds in all at most; then the profile opens anyway). How long the sync itself takes depends on how many sessions and stores you have and on the machine's load. Second, the launcher may be unsigned — written before signing was added, or generated on a machine where `codesign` was missing. Gatekeeper re-scans an unsigned bundle on every launch: about 1.7 s to the first process, against about 0.5 s for an ad-hoc signed one (both measured without the sync). `claude-multi doctor` reports unsigned launchers, and `claude-multi app <email>` regenerates and signs one.

**A launcher opens a dialog saying claude-multi is not installed.** The stub could not find the CLI in `/usr/local/bin`, `~/.local/bin`, `~/bin`, `/opt/homebrew/bin` or the checkout it was generated from. Re-run `./install.sh`, then `claude-multi app <email>` (or just open the profile once from the terminal, which refreshes a stale launcher).

**The background job is not running.** `claude-sessions-sync --status` shows the interval, the deletion mode read out of the installed plist, the launchd run count and last exit code, and the last log lines. If it is not installed, `--install`. The full log is at `~/.claude/logs/claude-sessions-sync.log`; anything the job wrote to stderr is in `~/.claude/logs/claude-sessions-sync.err.log`, and `--status` mentions that file when it is non-empty.

**Sessions still don't match.** Run the dry run — plain `claude-sessions-sync`, no flags. It names the deletion mode, lists every store it found, the exact counts, the first 15 records it would write and the first 10 it would remove, and a “left untouched this run” section for anything it could not read. A profile that has never been signed in has no store yet, so there is nothing to merge into it; with fewer than two stores the dry run says so and stops.

**I deleted a session in one account and it is still in the others.** That is the default, and it is deliberate: deletions do not propagate. Delete it in the other accounts by hand. Be careful with running `claude-sessions-sync --apply --propagate-deletions` for this: it applies *every* deletion marker in every store, not just the one you have in mind, so any session you ever deleted in only one account disappears from the others too. Run it without `--apply` first — the dry run lists every session it would remove. To make the background job do it from now on, reinstall it with `claude-sessions-sync --install --every 1m --propagate-deletions`. Both `claude-multi doctor` and `claude-sessions-sync --status` tell you which mode the installed job runs in.

**`claude-multi list` shows `-` in the ACCOUNT column.** That column is read with whichever `python3` the tool found, out of each profile's own `config.json`; a `-` means the profile has never signed in, or no working interpreter was found. Run `claude-multi doctor` to see which one it picked. See [Requirements](#requirements).

**A profile won't delete.** Close that profile's window first; `claude-multi remove` refuses while the instance is running, and refuses without a terminal to confirm on.

**"another run is already in progress".** The background job holds the lock. It is harmless — the run exits 0 having done nothing, and the next one picks the work up.

## Safety and limitations

Stated plainly, because you are about to run this against your own data:

- **Unofficial.** Not endorsed by, affiliated with, or supported by Anthropic. Nobody promised these file locations would stay put.
- **It reads and writes local application files.** Specifically the per-account session-record directories, plus its own log, error log, lock and backups under `~/.claude/` — and deletion markers in those same directories when you run it with `--propagate-deletions` or `--restore`, and `~/Library/LaunchAgents/io.github.claude-multi.sync.plist` when you install the background job. It does not touch conversation transcripts, it takes a backup before its first apply and before any run that deletes anything, and it cancels the destructive part of a run if that backup fails — but it is still your data.
- **`setup` force-quits Claude Desktop.** Every window, before it starts and again between accounts, escalating to `SIGTERM` and `SIGKILL` if a window does not exit within 20 seconds. In-flight Claude Code sessions in the app are interrupted.
- **A Claude Desktop update could change the session-record format.** If that happens, the sync would need updating. The dry run is the safe way to check after any major app update.
- **Synced sessions appear after a restart or account switch**, not instantly, because the app reads the list only at those moments.
- **Renames and pins do not follow a session into an account that already knows it.** The record files do carry the new title and an `isStarred` flag, and a session an account has never seen arrives with them. But for sessions it already knows, Claude Desktop shows the title and pin from its own internal storage, not from these files: measured, a profile restarted with the new title and the pin in its record file still showed the old title, unpinned. That storage is the app's own database; this tool does not touch it (editing it while the app runs would corrupt it, and its format is private). Rename and pin in each account where it matters. (Pinning or renaming alone also does not advance `lastActivityAt`, so those edits travel only alongside later activity in the session.)
- **A "No folder" session shows up under a folder name in the other accounts.** Claude runs such a session in a scratch folder inside the profile that created it (`…/scratch-workspaces/…/scratch-<date>-<id>`) and groups it under "No folder" only in that profile. Other accounts do not recognise the folder as their own scratch space, so they list the session under its folder name, e.g. `scratch-2026-01-01-abc123`. The session works normally — the folder exists and the conversation is there. The path is not rewritten on purpose: Claude locates the conversation through it. If you later remove the profile that created such a session, its folder goes with it.
- **Deletion is opt-in and off by default.** A default run never unlinks a record, never propagates a marker and never clears a stale one, so a session you delete in one account stays in the others until you pass `--propagate-deletions`. The price of that default is that it also refuses to write a record into a store that already holds a marker for that session — stale or not — so such a store simply stays as it is. (`--no-delete` still exists as a deprecated no-op naming the default.)
- **Launcher names contain the account address.** They sit in `/Applications` by default and are indexed by Spotlight, so anyone who can see that folder or search your Mac can read which accounts you use. Set `CLAUDE_MULTI_LAUNCHER_DIR=~/Applications` on a shared or screen-shared machine.
- **The dry run prints your own session titles and profile names.** It says so at the end. Redact it before pasting it into a bug report.
- **Each profile is a separate login.** Separate cookies, separate app settings, separate MCP configuration — copied from your main profile at creation only if you ask for it. That is the point, but it means per-profile settings do not follow you.

## Roadmap / not planned

**Not planned: a GUI wrapper.** It was considered and dropped. The one genuinely awkward step — signing each new profile in, alone, through the browser and the `claude://` callback — cannot be automated by a GUI any more than by a CLI, so a wrapper would add an app to maintain without removing the friction. **Windows and Linux** are likewise not on the roadmap: they need a different profile-isolation and URL-scheme story per platform, not a port of these scripts (see the FAQ). Both would be welcome as PRs from someone who actually runs that platform.

## Contributing

Issues and pull requests are welcome — especially: other macOS versions and Claude Desktop builds, more accurate observations about the session-record format, and `doctor` checks that would have saved you an hour.

If you change behaviour that depends on how Claude Desktop stores things, say in the PR how you measured it, on which app version. Everything in this README that sounds like a fact was measured on a real machine, and that is the standard to keep.

Code is Bash and Python 3 standard library, no dependencies, macOS/BSD userland. Keep every user-facing string in English, and never commit real account UUIDs or email addresses — the examples are `work@example.com` and `personal@example.com`.

## License

MIT. See [LICENSE](LICENSE).

---

**Keywords:** Claude Desktop multiple accounts macOS, multiple Claude accounts one Mac, Claude Code session sync, Claude Desktop profiles, run two Claude apps at once, Electron user-data-dir multiple instances.
