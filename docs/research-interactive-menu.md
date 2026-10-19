# Interactive menu/wizard for `agman` — research note

Research date: 2026-10-17. Verified against primary sources only: `bash(1)`
man page shipped with `/bin/bash` 3.2.57 on macOS (the exact target runtime),
`help select` / `help read` running under that same binary, the POSIX `test`
and `stty` specifications, and the actual man pages / source of `fzf`,
`dialog`, `whiptail`, `git`, `npm`, `aws`, `rustup`, and `n`.

## Summary — recommended approach

Use a **two-tier** design, both guarded behind a TTY check:

1. **Baseline (zero-dependency, the hard constraint):** `select` + `PS3` for the
   top-level action menu, `printf`-prompt + `read -r` for free-text (`[Enter]`
   for a bracket default), `read -s` (or the existing `stty -echo` idiom) for
   secrets, and `read -n 1` + `case` for single-key confirmations. All of these
   are full bash 2.0 features flagged as present in bash 3.2.57 (`help read`),
   and all are portable across macOS bash 3.2, Linux bash, WSL, and Git Bash.

2. **Optional enhancement (like the existing `jq`/`python3` handling):** if
   `command -v fzf` succeeds and stdin/stdout are a TTY, offer an `fzf` selector;
   otherwise fall back to `select`. This matches the project's established
   "use it if present, degrade gracefully otherwise" pattern.

**Concretely, for `agman` with no arguments:**

```bash
main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  if [ -z "$1" ] && [ -t 0 ] && [ -t 1 ]; then
    # no args + interactive terminal -> menu
    interactive_menu; return
  fi
  case "$cmd" in ... esac
}
```

Each menu action should call the existing `cmd_*` functions directly, so the
menu is a thin dispatcher — it must *not* be a pipeline (see §3), because
`select`/`read` need the real TTY on fd 0.

Recommended against: hand-rolling an ANSI arrow-key menu (§7) and `dialog` /
`whiptail` (§5) for a zero-dependency tool.

---

## 1. The `select` builtin (bash 3.2)

Syntax, per `bash(1)` (the 3.2.57 man page on this machine) and `help select`:

```
select name [ in word ] ; do list ; done
```

Behavior (verbatim from the man page, "Compound Commands"/`select`):

> "The list of words following `in` is expanded, generating a list of items.
> The set of expanded words is printed on the standard error, each preceded by
> a number. If the `in word` is omitted, the positional parameters are printed.
> The PS3 prompt is then displayed and a line read from the standard input. If
> the line consists of a number corresponding to one of the displayed words,
> then the value of `name` is set to that word. If the line is empty, the words
> and prompt are displayed again. If EOF is read, the command completes. Any
> other value read causes `name` to be set to null. The line read is saved in
> the variable `REPLY`. The list is executed after each selection until a
> `break` command is executed."

(`help select` from `/bin/bash 3.2.57` is word-for-word the same; "PS3" is
documented under "Shell Variables": *"PS3 — The value of this parameter is used
as the prompt for the select command."*)

Source: `bash(1)` § COMPOUND COMMANDS; GNU Bash Reference Manual,
https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html ;
`PS3` at https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html .

Capabilities and limits relevant to this design (**empirically verified against
`/bin/bash 3.2.57`** on this machine):

- **More than 9 items:** yes. Numbers are unbounded (`10)`, `11)`, …). With 12
  short items the built-in renderer lays the list out in *columns* (tightly
  tab-separated) rather than one-per-line, based on `$COLUMNS`:

  ```
  1) alpha    3) gamma    5) epsilon   7) eta      9) iota    11) lambda
  2) beta     4) delta    6) zeta      8) theta   10) kappa   12) mu
  pick>
  ```

  So `select` works past 9 entries but the layout is not a clean single-column
  numbered menu — worth knowing before promising fixed row numbers in docs.

- **Arrow keys:** not supported. `select` reads one line and parses it as an
  integer. Pressing ↑ sends `ESC [ A` (three bytes); that does not parse as a
  number, so `name` is empty and `REPLY` holds the raw escape bytes (verified:
  feeding `\033[A` yields `REPLY=\033[A`, `name=`). Only number-then-Enter works.

- **Empty input:** the list and `PS3` prompt are redisplayed (verified).

- **EOF / Ctrl-D:** the `select` command completes (loop exits; nonzero status).

- **Menu goes to stderr, prompt to stderr; the chosen *value* is in `name`
  (not `REPLY`).** Capture/parse accordingly.

Idiom for `agman` (bash 3.2-safe, works with `set -u`):

```bash
interactive_menu() {
  local actions=("Create a profile" "Switch / activate a profile" \
                 "Stealth mode" "Turn profiles off" "Run doctor" "Quit")
  PS3='Choose an action: '
  select choice in "${actions[@]}"; do
    case "$choice" in
      "Create a profile")       cmd_create_ask ;;   # prompt name, then cmd_create
      "Switch / activate"*)     cmd_use_ask ;;
      "Stealth mode")           cmd_stealth_ask ;;
      "Turn profiles off")      cmd_off ;;
      "Run doctor")             cmd_doctor ;;
      "Quit")                   break ;;
      *) printf 'pick a number 1-%s\n' "${#actions[@]}" >&2 ;;
    esac
    break   # one-shot menu; re-run select if you want to loop
  done
}
```

Caveats with `agman`'s `set -euo pipefail`:

- Keep the `select` loop in `main`, not inside a pipeline or command
  substitution — in a pipeline its stdin is the pipe, not the terminal.
- `select` redraws on empty/invalid input forever until a valid number, `break`,
  or EOF, so a "Quit"/cancel entry is essential.
- Under `set -u`, only reference `$REPLY`/`$choice` inside the body where they
  are defined (they are, at that point).

---

## 2. Prompting primitives: `read`

`help read` from `/bin/bash 3.2.57` gives the exact 3.2 option set:

```
read [-ers] [-u fd] [-t timeout] [-p prompt] [-a array] [-n nchars] [-d delim] [name ...]
```

So **all of `-e -r -s -u -t -p -a -n -d` exist in bash 3.2** and are portable.
Per-option semantics from `bash(1)` (§ SHELL BUILTIN COMMANDS, `read`):

- `-p prompt` — display `prompt` on **standard error**, without a trailing
  newline, **"only if input is coming from a terminal."**
- `-s` — *"Silent mode. If input is coming from a terminal, characters are not
  echoed."*
- `-e` — *"If the standard input is coming from a terminal, readline is used to
  obtain the line."* (Enables readline editing/history for that read.)
- `-n nchars` — *"read returns after reading `nchars` characters rather than
  waiting for a complete line of input."* (Verified: `printf y | read -n 1 k`
  returns immediately with `k=y`, no Enter required.)
- `-r` — *"Backslash does not act as an escape character."* (Always use it for
  token/path input; `agman` already does `IFS= read -r` throughout.)
- `-t timeout` — timeout and return failure if no complete line within
  `timeout` seconds.

Source: `bash(1)`; https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html#index-read

Portability notes:

- **`read -i <text>` (readline *default* value) is NOT in bash 3.2** — it was
  added in bash 4.0 and is absent from the 3.2 synopsis above. The bash 3.2
  idiom for "default shown in brackets, Enter to accept" is the one `agman`
  already uses in `cmd_cloud` (line ~2210):

  ```bash
  printf 'Cloud URL [%s]: ' "$CLOUD_DEFAULT_URL"
  IFS= read -r url || true
  [ -n "$url" ] || url="$CLOUD_DEFAULT_URL"
  ```

- `-e`/`-s`/`-p` are all *TTY-gated* (per the quotes above): under a pipe they
  degrade safely. `-s` alone is enough to hide input; the `stty -echo` approach
  `agman` uses for tokens (lines ~1698–1701 and ~2227–2230) is functionally
  equivalent and is retained for consistency. Both work on 3.2.

- **`read` returning nonzero** (EOF/Ctrl-D/timeout) must be tolerated under
  `set -e`; the existing codebase already uses the correct pattern
  `IFS= read -r x || true`.

- `read -n 1` reads a single *byte* case-sensitively and leaves any further
  pasted characters in the terminal input queue for the next read; for a
  strict single-key confirmation, drain any queued input afterward (or use
  `stty -icanon` — see §7).

---

## 3. TTY / interactivity detection

Three mechanisms, with the important caveat that **only `-t` is the right test
inside a script**:

- **`test -t FD`** — `bash(1)` § CONDITIONAL EXPRESSIONS (and `help test`):
  *"`-t FD` True if FD is opened on a terminal."* POSIX `test` says the same:
  *"True if file descriptor number `file_descriptor` is open and is associated
  with a terminal."* POSIX additionally notes historical implementations let
  the fd be omitted defaulting to **1** — so use an explicit `0`/`1`/`2`.

  This is how `agman` already gates its prompts: `if [ ! -t 0 ]; then die ...`
  (trust prompt, line ~987) and `[ -t 0 ] || die "not a terminal; pipe a token…"`
  (login, line ~1686).

- **`$-` containing `i`** — `bash(1)` § SPECIAL PARAMETERS: *"`-` Expands to the
  current option flags … such as the `-i` option."* And § INVOCATION:
  *"PS1 is set and `$-` includes `i` if bash is interactive."*

- **`$TERM` / `$PS1`** — heuristics; `PS1` is set in interactive shells but can
  be set/unset manually, and `TERM` can be set when there is no TTY (e.g. CI).

  Source: `bash(1)` § INVOCATION ("An interactive shell is one started without
  non-option arguments and without the `-c` option whose standard input *and
  standard error* are both connected to terminals (as determined by
  `isatty(3)`), or one started with the `-i` option.").

  https://www.gnu.org/software/bash/manual/html_node/Interactive-Shells.html

**The decisive point for `agman`:** bash runs a script (file argument) as a
*non-interactive* shell even when fds 0/1 are a terminal — so **`$-` will NOT
contain `i`, and `PS1` will be unset, inside `bin/agman` regardless of whether
the user is sitting at a terminal.** `[[ $- == *i* ]]` is therefore the wrong
test here. Use `[ -t 0 ]` (stdin — needed to read) and, when printing a full
menu to a captured/pipe destination would be garbage, also `[ -t 1 ]`.

**Fallback convention:** when stdin is not a TTY (piped, CI, `</dev/null`), do
**not** enter the menu — print help/usage and exit, or read from `/dev/tty`
only if a prompt is truly mandatory. `rustup-init.sh` (a POSIX `sh` installer)
does exactly the latter: it re-execs itself with `< /dev/tty` so the binary can
prompt, and errors with *"Run with -y to accept defaults"* when there is no
interactive stdin (rustup-init.sh, lines 202–208).

Extra: `select`/`read` need fd 0 to be the TTY directly, so **do not put the
menu loop in a pipeline**; a pipeline makes its stdin the pipe, defeating `-t 0`.

Sources: POSIX `test`, https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html ;
`bash(1)`; rustup-init.sh, https://github.com/rust-lang/rustup/blob/master/rustup-init.sh

---

## 4. `fzf` as an optional selector (with `select` fallback)

`fzf` is "an interactive filter program for any kind of list" — `fzf(1)`
(0.74.5). It reads a list on stdin, lets the user fuzzy-filter and arrow-navigate
it on a real TTY, and prints the chosen line(s) to stdout. Relevant options,
all from `fzf(1)` (`man/man1/fzf.1` in the junegunn/fzf repo):

- `--height=[~]HEIGHT[%]` — display fzf below the cursor as a drop-in list
  instead of full-screen (the key option for non-intrusive use).
- `--reverse` / `--layout=reverse` — list grows upward from the prompt (the
  de-facto modern default styling).
- `-m, --multi[=MAX]` — allow multiple selections (tab-marked), printed on
  separate lines.
- `--ansi` — interpret ANSI color escapes in the input list.
- `--pointer=STR`, `--marker=STR`, `--prompt=STR` — the ">" cursor, the ">"
  multi-select marker, and the prompt string.
- `-q, --query=STR` — initial query; with `-1, --select-1` ("do not start the
  finder if there is only one match") and `-0, --exit-0` ("…if no match") you
  can make it single-shot and safe in scripts.
- `-e, --exact`, `--tac`, `--cycle`, `--no-sort`, `--expect=KEY[,..]`,
  `--preview=COMMAND`, `--bind=…`.

Source: fzf man page https://github.com/junegunn/fzf/blob/master/man/man1/fzf.1 ;
project/references https://github.com/junegunn/fzf

The standard "use fzf if present, else fall back to `select`" pattern
(fzf detection via `command -v`, which is POSIX):

```bash
pick_one() {                       # pick_one <label> <item...> -> echoes choice
  local label="$1"; shift
  if [ -t 0 ] && [ -t 1 ] && command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$@" \
      | fzf --height=10 --reverse --prompt="$label> " --ansi
  else
    PS3="$label> "
    select choice in "$@"; do
      [ -n "$choice" ] && { printf '%s\n' "$choice"; break; }
    done
  fi
}

profile="$(pick_one "Activate profile" agman list --names 2>/dev/null || true)"
```

Fallback quality notes (what a clean bash 3.2 fallback must handle):

- `select` needs the items as an array/`"$@"` (bash 3.2 has indexed arrays —
  `agman` already relies on no-assoc-arrays, so this is fine).
- `select` is one-shot per loop; wrap in a function and `break` on a valid
  choice, or `continue` to re-prompt.
- Both paths must gate on TTY (§3), and `fzf` auto-degrades to non-interactive
  anyway (it errors on `stdin`/`stdout` not being a TTY unless `--height` is
  set and a TTY is present), so the explicit `[ -t 0 ]` check mainly decides
  whether to run the `select` branch at all.

---

## 5. `dialog` / `whiptail` (ncurses menu/input boxes)

Both provide reusable ncurses widgets callable from shell, returning the result
on **stderr**. From their man pages:

- **`whiptail(1)`** (Debian `newt`, 0.52.5): *"display dialog boxes from shell
  scripts"*. Implements `--yesno`, `--menu`, `--inputbox`, `--passwordbox`,
  `--msgbox`, `--textbox`, `--checklist`, `--radiolist`, `--gauge`, plus
  `--title`, `--backtitle`, `--default-item`, `--nocancel`, `--defaultno`. Menu
  entries are `<tag> <item>` pairs; the chosen *tag* is printed on stderr;
  UP/DOWN, tag first-letter, and number-key hotkeys navigate. Exit status 0 =
  Ok/Yes, 1 = Cancel/No, **255 = Esc/error**.
  Source: https://manpages.debian.org/unstable/whiptail/whiptail.1.en.html

- **`dialog(1)`** (Thomas E. Dickey): the superset — `--menu`, `--inputbox`,
  `--inputmenu`, `--form`, `--yesno`, `--msgbox`, `--checklist`, `--gauge`,
  `--infobox`, `--mixedgauge`, etc. Its `--menu` navigates with cursor keys,
  tag hot-key, or number keys **1 through 9** (integers only — a real limit for
  menus > 9). Notably, its own man page warns on `--stdout`: *"using it in
  portable scripts is not recommended, since curses normally writes its screen
  updates to the standard output."*
  Source: https://manpages.debian.org/unstable/dialog/dialog.1.en.html

**Platform availability (why they're avoided here):**

- **Not on macOS.** This machine ships neither `dialog` nor `whiptail`
  (verified: `command -v dialog` / `command -v whiptail` both empty), and
  Apple's base system ships no ncurses dialog binary — `dialog` is only
  available via Homebrew, and `whiptail` effectively not at all natively.
- On Linux they are repo-packageable — `whiptail` is a Debian/Ubuntu `newt`
  utility in the main `utils` section (packages present across `jammy` and
  `noble`) and is the default `debconf` menu frontend, so it is commonly
  preinstalled on Debian/Ubuntu; `dialog` is packaged in all major distros but
  is not guaranteed present on a minimal install, Alpine, or macOS.
  Source: https://packages.ubuntu.com/search?keywords=whiptail&searchon=names

These are dependencies in exactly the way `agman`'s constraints forbid, their
results land on stderr (requiring `3>&1 1>&2 2>&3` juggling to capture), and
`dialog`'s own docs say the obvious capture path (stdout) is non-portable. For
a zero-dependency pure-bash tool they are the wrong default — which is why the
real-world bash tools that do use them (`raspi-config`, `sbopkg`) ship
*in* distros where `whiptail`/`dialog` is already present.

---

## 6. Real-world interactive/wizard CLIs — what they actually do

Findings, with the key verification that **very few are actually pure bash**;
most interactive wizards live in another runtime. UX conventions, however, are
consistent and portable:

- **`git add -p` / `git add -i`** — not bash (C now; historically
  `git-add--interactive.perl`). This is the canonical *single-key modal loop*:
  it prints a hunk, then waits for one keystroke, `case`-dispatched:

  ```
  y - stage this hunk
  n - do not stage this hunk
  q - quit; do not stage this hunk or any of the remaining ones
  a - stage this hunk and all later hunks in the file
  d - do not stage this hunk or any of the later hunks in the file
  g - select a hunk to go to
  / - search for a hunk matching the given regex
  j - leave this hunk undecided …
  J - … and any later hunks
  e - manually edit the current hunk
  ? - print help
  ```

  A plain `case` over a single `read -n 1` (`?` for help) is the portable
  pure-bash equivalent we'd use for confirm/select-per-option flows.
  `git` even has `interactive.singleKey` ("send only the menus, no
  confirmation") — the "don't require Enter for menu keys" toggle.
  Source: https://git-scm.com/docs/git-add (INTERACTIVE MODE)

- **`npm init`** — not bash (Node). Documents the *guided questionnaire* pattern
  and its escape hatch: *"It will ask you a bunch of questions … You can also
  use `-y`/`--yes` to skip the questionnaire altogether."* Convention: a
  non-interactive flag that answers every prompt.
  Source: https://docs.npmjs.com/cli/v10/commands/npm-init

- **`aws configure`** — not bash (Python, `awscli`). Canonical **bracket-default**
  prompting: *"When you are prompted for information, the current value will be
  displayed in [`brackets`]. If the bracket contains `None`, the value will be
  set to `None` if you press Enter; otherwise re-enter."* Example:

  ```
  Default region name [None]: us-west-2
  Default output format [None]:
  ```

  Exactly the `printf 'Label [%s]: ' + read + [ -n "$x" ] || x=default` idiom
  in §2 (and already used by `agman` for the cloud URL).
  Source: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/configure/index.html

- **`gcloud init`** — not bash (Python). Interactive region/account selection
  with numbered lists and `[Enter]` for defaults; same conventions.

- **`rustup-init.sh`** — the one genuinely-shell wizard here. Its numbered
  "Proceed / Customize / Cancel" menu historically lived in this POSIX `sh`
  script; today (master, 2026) the menu lives in the Rust binary and the shell
  script is a bootstrap that (a) re-execs with `< /dev/tty` to give the binary
  a terminal, and (b) errors "Run with `-y` to accept defaults" when stdin is
  not interactive. This is the reference pattern for **"interactive shell +
  non-interactive `-y` fallback"**.
  Source: https://github.com/rust-lang/rustup/blob/master/rustup-init.sh

- **`nvm`** (bash `nvm.sh`) and **`pyenv`** (bash `bin/pyenv`) — both pure
  bash/POSIX, and notably **non-interactive**: neither uses `select` nor
  prompts for input (verified by grepping both sources for `read`/`select`/`PS3`
  confirm prompts). They stick to subcommands + flags and let terminal
  integration (completion) do the "menu". This is a meaningful data point: the
  two most popular pure-bash tools in this exact domain *deliberately avoid*
  interactive wizards.
  Sources: https://github.com/nvm-sh/nvm ; https://github.com/pyenv/pyenv

**Shared conventions worth copying** (consistent across the above): numbered
list or single-letter menu, not both at the same depth; `y/N` defaults uppercased
to signal the safe default; defaults in `[brackets]`; Enter accepts the default;
a `-y`/`--yes` flag skips all prompts; a Quit/Cancel/`q` key always exits;
help is `?` or a dedicated key; context is printed *before* the prompt and
never scrolls away.

---

## 7. Custom arrow-key menus in pure bash (ANSI escape sequences)

**Yes, it's done in the wild and is portable to bash 3.2 — but it is the least
robust option and usually not worth it vs. `select` or optional `fzf`.**

Canonical primary-source example: `n` (tj/n, a pure-bash version manager)
implements an arrow-key delete/select menu with exactly the bash features
available in 3.2 (`read -n/-s/-r/-t`, `$'...'`, `[[ ]]`). Its loop (bin/n,
`menu_select_cache_versions`):

```bash
printf "Use up/down arrow keys to select…, return key to install, d to delete, q to quit\n"
ESCAPE_SEQ=$'\033'
while true; do
  read -rsn 1 key
  if [[ $key == "$ESCAPE_SEQ" ]]; then
    read -rsn 1 -t 1 tmp          # next byte with a short timeout
    if [[ $tmp == '[' ]]; then
      read -rsn 1 -t 1 arrow      # final byte: A (up) B (down) C (right) D (left)
      case "$arrow" in
        B) selected="$(next_version_installed "$selected")" ;;   # down
        A) selected="$(prev_version_installed "$selected")" ;;   # up
      esac
      display_versions_with_selected "$selected"
    fi
  elif [[ $key == "" ]]; then      # enter
    ...
  elif [[ $key == 'q' ]]; then ...; break; fi
done
```

Source: https://github.com/tj/n/blob/master/bin/n (lines ~541–634). (Note `n`
still requires bash 4 for other features elsewhere, but this *specific* code is
only `read [-r -s -n -t]` + `[[ ]]` + `$'…'`, all present in 3.2.)

How it works, and the pitfalls:

1. **Raw mode.** The terminal must be in raw/non-canonical mode so `read` gets
   each byte without Enter. `read -n 1` alone is not enough — in cooked mode the
   kernel still line-buffers and echoes. You need `stty -echo -icanon`
   (old-style `stty raw`) plus explicit restore, e.g. `stty -echo; trap 'stty
   echo' EXIT; read -rsn 1 k …; stty echo`. (`n` wraps its menu in `stty -echo`
   / `stty echo` at lines 344/352.) POSIX `stty`:
   https://pubs.opengroup.org/onlinepubs/9699919799/utilities/stty.html

2. **ESC vs. arrows is ambiguous.** `ESC` alone is one byte `0x1b`; arrows are
   `0x1b 0x5b 0x41/42/43/44` (`ESC [ A/B/C/D`). You must read the following
   byte **with a timeout** to distinguish (the `read -rsn 1 -t 1 tmp` trick).
   On bash 3.2 `read -t` takes an integer (fractional seconds arrived in 4.0),
   so the timeout granularity is whole seconds — a `-t 1` pause is noticeable
   but acceptable for Esc.

3. **Byte-oriented, not character-oriented.** Arrow sequences are pure ASCII
   control bytes, so this is locale/UTF-8 safe *for the keys themselves*, but any
   menu you redraw must re-emit ANSI cursor/screen control for arbitrary
   (possibly multibyte) item text, and clearing/redrawing (`\033[1A\033[2K` to
   move up and erase a line, as `n` does) is where most bugs live (scrollback,
   wrapped lines, narrow terminals, `$COLUMNS`/`$LINES`).

4. **TTY-only, strictest of all.** Requires both fds be a terminal and the raw
   mode must be restored on every exit path (`trap ... EXIT`), or a crash leaves
   the user's terminal echo-disabled — the classic "typed nothing appears" bug.
   This is worse than `select`/`read -p`, which are safe if mis-guarded.

5. **Portability of the pieces is fine;** portability of the *loop* is the
   problem. `read -rsn 1`, `read -t`, `$'\033'`, and `[[ ]]`/`case` all work on
   macOS bash 3.2 and Linux/WSL; the fragility is stochastic (terminal
   emulators, `TERM`, column wrapping, key-repeat, paste), not syntax.

**Verdict:** if arrow-key selection is desired, `fzf` (optional, §4) delivers
exactly this UX with none of these pitfalls, and `select` gives a zero-dep
fallback. A hand-rolled `read -n 1` ESC-state machine is only justified if you
need arrow navigation *and* cannot allow `fzf` as an optional dependency — in
which case `n`'s loop above is the reference implementation to copy, including
its `stty` + `trap` guard.

---

## Appendix — exact runtime facts

- Target interpreter on this machine: `/bin/bash` is **GNU bash 3.2.57** (the
  stock macOS bash). All `help read`/`help select` output above, and the
  `select`/`read -n 1`/`read -s`/arrow-key experiments, ran under it directly.
- `dialog`, `whiptail`, `fzf` are **not installed** here (verified) — which is
  precisely the "stock machine" the zero-dependency constraint covers.
- `agman` already contains the correct idioms to reuse: `[ -t 0 ]` gating
  (lines ~987, ~1686), `printf '…[%s]: '` + `read -r` + default-if-empty
  (lines ~2210–2214), `stty -echo` secret entry (lines ~1698–1701, ~2227–2230),
  and `IFS= read -r reply || true` + `case` for y/N confirmations
  (lines ~991–993, ~1523–1526).