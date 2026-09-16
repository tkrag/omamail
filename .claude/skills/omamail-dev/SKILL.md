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

`test-js` (`node ui/tests/*.js`, no build step) needs only `node`, already
present. `qml-check` and `test-qml` need Qt 6's `qmllint`/`qmltestrunner` —
these **are** installed here, just not on `PATH`: the Makefile already points
`QMLLINT` at `/usr/lib/qt6/bin/qmllint`, and `QMLTESTRUNNER` falls back to
`/usr/lib/qt6/bin/qmltestrunner` when neither `qmltestrunner6` nor
`qmltestrunner` resolves on `PATH`, so plain `make qml-check` / `make
test-qml` (or `python3 tests/run_qml_native.py /usr/lib/qt6/bin/qmltestrunner
-input ui/tests/qml`) work without extra setup. Always run these after
touching `ui/` — don't assume Qt tooling is unavailable without checking
`/usr/lib/qt6/bin/` first.

`make test-rust` is just `cargo test --locked --features
integration-test-credentials` — always pass that feature flag, or IMAP/JMAP
integration tests that exercise real credential storage fail with
`auth_signed_out` for reasons that have nothing to do with your change.

## Running a local build against the live Omarchy shell

**Use `make install`, not `./dev run`, unless you specifically need the
`OMAMAIL_BIN` override.** `make install` (→ `install-backend-local`, which
builds `--release` and runs `python3 scripts/backend-runtime.py
install-local`, then `scripts/link-plugin.sh`) does three things: builds a
release binary, installs it as *the* backend Omarchy launches (replacing the
Marketplace one), and symlinks `~/.config/omarchy/plugins/omamail` to this
checkout so the QML/JS also comes from here — then restarts the shell for
you. This is what the Makefile itself calls out as "development only: the
Marketplace installs the plugin for ordinary users," i.e. the sanctioned way
to run your own build day to day. Revert with `make install-plugin` (wipes
the runtime and reinstalls the pinned release fresh) or manually via
`python3 scripts/backend-runtime.py uninstall`.

`./dev run` only builds a debug binary and prints `OMAMAIL_BIN=<path>` — it
changes nothing by itself. That variable has to reach the **Quickshell
process's own environment** (`ui/Service.qml` reads it via
`Quickshell.env("OMAMAIL_BIN")`), and `omarchy restart shell` deliberately
launches the shell through Hyprland (`hyprctl dispatch
'hl.dsp.exec_cmd("omarchy-launch-shell")'`) specifically so it inherits "the
canonical session environment, not transient variables from a terminal" (see
`omarchy-restart-shell`'s own comment) — so `export OMAMAIL_BIN=...` in a
terminal and then restarting the shell does **not** pick it up. Reaching for
`OMAMAIL_BIN` for real means getting it into Hyprland's own process
environment (e.g. an `env =` line in the Hyprland config, which needs a
fresh Hyprland session to take effect) — heavier than it's worth for a
single test. `make install` sidesteps all of this because the resulting
binary needs no environment variable at all.

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

## Credential storage and the account-startup read

Rust (`src/auth/credentials.rs` → `src/credentials/`) owns the platform
keyring; on Linux that's `src/credentials/secret_service.rs` over D-Bus. QML
never sees a secret directly. Separately, `ui/Service.qml::restoreAccountRegistry()`
reads the account *list itself* (`accounts.read`, emails/hosts/labels — no
secrets) from a plain watched file; that read now retries a few times before
falling back to onboarding, specifically because it can lose a race at login
(see below) and used to strand a real, already-configured account behind the
"Add a mailbox" screen forever with no retry. If accounts.json has a real
account but the app shows onboarding, that startup race — not a lost
password — is the first thing to suspect; check `omamail accounts list
--json` against the live app's state before assuming a credential is gone.

**This machine specifically** has SDDM autologin enabled
(`/etc/sddm.conf.d/autologin.conf`), which skips the login password
`pam_gnome_keyring` would otherwise use to unlock the login keyring — so the
keyring (and anything reading from it right after boot) can start locked for
a few seconds every session. That's a system-level interaction, not
omamail's fault, but omamail's *own* one-shot startup reads were not
resilient to it before the retry fix above.

Also on this machine: `gnome-keyring-daemon` itself crashes somewhat
regularly (`gkd_secret_service_get_pkcs11_session: assertion 'client'
failed`, cascading to a fatal `g_variant_new` type mismatch) — a known,
longstanding upstream bug ([Debian #1147303](http://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2121437.html),
[GNOME GitLab #144](https://gitlab.gnome.org/GNOME/gnome-keyring/-/work_items/144))
triggered by concurrent Secret Service access. `secret_service.rs` opens a
brand-new D-Bus connection and DH-encrypted session on every single
credential lookup rather than reusing one, which plausibly exercises that
race more than apps holding a single session — worth fixing (cache/reuse the
session) as a follow-up, but not yet done; not something fixable in omamail
alone since the crash is inside the daemon's own code, and nothing here
duplicates an existing report on either tracker as of 2026-09-16.

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

- PR #1 (merged) — the IMAP archive shortcut ("e") now routes each message
  into `<ArchiveRoot>/<year>` (the message's own date, not the archive date),
  creating the year folder on first use, to match a long-lived
  `Archives/<year>` layout instead of one ever-growing mailbox. See
  `src/providers/imap/mutation.rs` (year bucketing, folder-create-then-move)
  and `src/providers/imap/read.rs` (`fetch_years`, `delimiter_of`, `exists`,
  `folder_listed`).
- PR #3 — `restoreAccountRegistry()` in `ui/Service.qml` retries a failed
  first `accounts.read` before falling back to onboarding. See "Credential
  storage and the account-startup read" above.
- Not yet done, worth picking up later: cache/reuse one Secret Service
  session in `src/credentials/secret_service.rs` instead of opening a fresh
  one per credential lookup — see the gnome-keyring section above.
