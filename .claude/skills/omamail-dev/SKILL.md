---
name: omamail-dev
description: How to build, test, and modify this omamail fork (Rust IMAP/JMAP/Gmail/Outlook backend + Qt/QML UI) — where behavior for a given feature lives, the dev/build/test loop, and how to run a local build without disturbing the Marketplace-installed plugin.
---

# Working on this omamail fork

This is a personal fork of `huacnlee/omamail`, the email client bundled with
Omarchy. `origin` is the fork (`tkrag/omamail`), `upstream` is the original
project. Use this skill whenever asked to change omamail's behavior — it
orients you before you go spelunking.

## Layout: Rust owns the wire, QML/JS owns the screen

- `src/` — Rust backend. `src/providers/<name>/` holds one mail protocol each
  (`imap`, `jmap`, `gmail_http`, `outlook`, `hey`). All wire-protocol parsing,
  IMAP command construction, and credential handling live here; nothing about
  IMAP framing should leak into QML.
- `ui/` — Qt/QML and its JavaScript. `ui/providers/` mirrors `src/providers/`
  one-to-one: a description, a registry entry, and a thin protocol/client
  pair per provider — but these JS files are presentation/labeling only
  (icons, labels, Gmail-label-vocabulary translation for optimistic UI).
  **The Rust side is the actual authority for what happens on the wire.**
  A JS file with the same shape as a Rust one (e.g.
  `ui/providers/ImapProtocol.js` vs `src/providers/imap/mutation.rs`) can
  drift from it — check whether the JS function is even called at runtime
  (`grep` for its name outside its own test file) before assuming it needs a
  matching change.
- `ui/account/` — one mailbox and the list of them; `Model.js` decides what a
  list does after an action (which rows leave which views).
- `ui/components/` — views only; they draw what they're given and decide
  nothing.
- Full map: see `AGENTS.md`'s "Layout" section and its module table.

## Where a given kind of change lives

- **A new IMAP action or a change to what a mutation does on the wire**
  (archive, trash, move, flag changes): `src/providers/imap/mutation.rs`
  (the `plan()` function decides add/remove flags + destination folder;
  the execution loop in `call_planned()` issues the actual commands) and
  `src/providers/imap/read.rs` (`Mailboxes`, folder discovery, special-use
  flag resolution via `resolve()`, and any new FETCH/LIST parsing). Keep
  cross-module helpers `pub(super)` and exposed through narrow functions
  (like `resolve()`, `exists()`, `delimiter_of()`) rather than exporting the
  private `Folder`/`Mailboxes` internals.
- **A label/icon/menu-visibility change**: `ui/providers/<Provider>.js` for
  presentation, `ui/account/Model.js` for what a list does after an action.
- **JMAP or Gmail equivalents of an IMAP change**: `src/providers/jmap/` and
  `src/providers/gmail_http/` — these protocols model "archive" as a label
  change, not a folder move, so equivalent logic looks different in shape.
- **Settings**: top-level app settings are declared in `manifest.json`
  (`"key"`/`"type"` entries); there is currently no per-account settings
  schema beyond the IMAP connection fields under an account's `imap` entry.

## Build and test loop

No Rust toolchain ships with the OS image here; this repo installed one via
`mise use -g rust@latest` (edition 2024 needs a recent stable). Cargo lives
at `~/.cargo/bin/cargo` (or `mise exec rust -- cargo ...`).

```sh
# Fast inner loop: build just the backend binary
cargo build --locked --target-dir target --bin omamail
# or: ./dev backend

# Rust unit + integration tests. --features integration-test-credentials
# swaps the OS keyring for an in-memory credential store — required in any
# sandboxed/headless environment (no secret-service), and also just faster.
cargo test --locked --features integration-test-credentials

# Formatting (CI-enforced)
cargo fmt          # apply
cargo fmt --check  # verify

# Full local gate before opening a PR
make test           # test-rust + test-js + test-shell + test-qml
make validate        # test + qml-check + `omarchy plugin validate .`
```

`test-js` (`node ui/tests/*.js`, no build step) and `test-qml` need only
`node`, already present. `qml-check` needs `qmllint` from Qt, which is **not**
installed in this environment — skip it if you haven't touched `ui/`, and say
so explicitly if you have and couldn't verify it.

`make test-rust` is just `cargo test --locked --features
integration-test-credentials` — always pass that feature flag, or IMAP/JMAP
integration tests that exercise real credential storage fail with
`auth_signed_out` for reasons that have nothing to do with your change.

## Running a dev build against the live Omarchy shell

```sh
./dev run
```

This builds the backend and prints an `OMAMAIL_BIN=...` path — it does
**not** touch the Marketplace-installed runtime. To actually use that build:
export `OMAMAIL_BIN` in the environment that starts `omarchy-shell`, restart
the shell through your normal session method, then reopen the plugin with
`omarchy shell shell toggle omamail '{}'`. `make install` (→
`install-backend-local` + `scripts/link-plugin.sh`) swaps in a dev build more
persistently; `make install-plugin` resets to a clean installed state.

## IMAP folder model, briefly

`src/providers/imap/read.rs::parse_folders()` builds a `Mailboxes` struct
from an IMAP `LIST` response: `special` maps RFC 6154 special-use flags
(`\Archive`, `\Trash`, `\Sent`, …) — falling back to name matching
("archive"/"archives", "trash"/"deleted items", …) when a server doesn't
advertise them — to the one folder that satisfies each. `mutation.rs::plan()`
turns a Gmail-vocabulary label change (`addLabelIds`/`removeLabelIds`, the
same request shape every provider's UI speaks) into IMAP flags and a
destination folder. `resolve(boxes, "\\Archive")` is the one sanctioned way
to find "the" archive folder — do not walk `Mailboxes.folders` directly from
outside `read.rs`; add a narrow `pub(super)` accessor instead (see
`exists()`/`delimiter_of()`/`folder_listed()` for the pattern).

## Security and commit conventions (from `AGENTS.md`, condensed)

- Credentials never cross a process boundary; nothing sensitive belongs in
  logs or error messages surfaced to the UI.
- A PR touching `ui/` needs before/after screenshots in its description —
  synthetic/redacted mail data, uploaded to GitHub's attachment host, never
  the repo.
- Commit/PR titles: `Fix ` for a bug fix, `Add ` for a new feature, prefixed
  by scope only for `ai:`/`docs:`/`website:`/`chore:` changes; otherwise no
  prefix. Title names the mechanism that changed, not a release-note
  sentence. Re-derive the title from the final diff, not the first commit.
- `make validate` (or at least `cargo test --features
  integration-test-credentials` plus `cargo fmt --check`) before opening a
  PR.

## This fork's own changes

- `feature/archive-year-subfolders` — the IMAP archive shortcut ("e") now
  routes each message into `<ArchiveRoot>/<year>` (the message's own date,
  not the archive date), creating the year folder on first use, to match a
  long-lived `Archives/<year>` layout instead of one ever-growing mailbox.
  See `src/providers/imap/mutation.rs` (year bucketing, folder-create-then-
  move) and `src/providers/imap/read.rs` (`fetch_years`, `delimiter_of`,
  `exists`, `folder_listed`).
