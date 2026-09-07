#!/bin/sh
# Link scalpel onto your PATH.
#
# Nothing here writes to ~/.claude. Telling Claude Code that scalpel exists is a
# change to your CLAUDE.md, and that is yours to make — the block to paste is
# printed at the end.
#
# POSIX sh, so it runs anywhere python3 does: a Linux box or a container with
# no zsh, an Alpine image with no bash. The test suite stays zsh; it runs where
# scalpel is developed, not where it is installed.
set -e

SRC="$(cd "$(dirname "$0")" && pwd -P)/scalpel"
BIN="$HOME/.local/bin"

if ! command -v python3 > /dev/null; then
  printf '%s\n' "scalpel needs python3." >&2
  exit 1
fi

mkdir -p "$BIN"
chmod +x "$SRC"

# Linked, not copied, so edits in this repo take effect on the next call. A
# stale copy that silently diverges from the repo is the failure worth avoiding.
ln -sf "$SRC" "$BIN/scalpel"
printf '%s\n' "linked $BIN/scalpel -> $SRC"

# A link onto a directory that is not on PATH installs cleanly and then is never
# found, which reads as "the tool is broken" rather than "the shell cannot see
# it". Say which one it is, and name the rc file for the shell in use.
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    case "${SHELL##*/}" in
      zsh)  rc='~/.zshrc' ;;
      bash) rc='~/.bashrc' ;;
      *)    rc='your shell rc file' ;;
    esac
    printf '\n%s\n%s\n\n%s\n' \
      "warning: $BIN is not on your PATH." \
      "add this to $rc:" \
      '    export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

printf '\n%s\n' "--- paste into ~/.claude/CLAUDE.md ------------------------------"
cat <<'BLOCK'

## Editing files

`scalpel` batches exact-match edits to one file into a single atomic call,
guarded by a content hash. Prefer it over the builtin Edit tool for three or
more changes to the same file, and over `sed -i`, `perl -pi`, and one-off
Python rewrites always; for one or two edits the builtin Edit renders a better
diff in review.

`scalpel read` prints the hash on its first line, and `edit` refuses to run
without it: pass it back as `--expect-hash`, or take the one printed on the
last line of the previous edit. `--unchecked` waives the check, for a file
nothing else can have touched. `--dry-run` shows the diff and writes nothing,
for checking a large batch first.

`scalpel read FILE --lines A-B,C-D` prints several windows under one hash.
Reach for it instead of `sed -n 'A,Bp'` on a file too long to read whole.

Five ways to say where, all in `scalpel edit --help`:

- `old`/`new` quotes what changes. It must be unique.
- `from` + `to`/`until` + `new` replaces a range by its two ends. Use it to cut
  a function or a test, or to replace a long body whose head and tail you
  know, instead of quoting the whole body as `old`.
- `insert` + `before`/`after` adds whole lines beside an anchor without
  repeating the anchor in the text.
- `append` and `prepend` need no anchor. Reach for one instead of `cat >>` and
  instead of rewriting a file to add to its end.
- `last: true` on any anchor takes the final occurrence, for the closing brace
  of a module that has no other context.

Do not guess the input format -- edits are a JSON array on stdin, and
improvising the shape costs more than the one call to check.
BLOCK
printf '%s\n' "---------------------------------------------------------------"
