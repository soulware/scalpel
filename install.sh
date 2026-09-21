#!/bin/sh
# Link scalpel onto your PATH.
#
# Nothing here writes to ~/.claude. Telling Claude Code that scalpel exists is a
# change to your CLAUDE.md, and that is yours to make — the block to paste is
# claude-md-block.md, printed at the end. Read that file to see the block; this
# script is for installing.
#
# POSIX sh, so it runs anywhere python3 does: a Linux box or a container with
# no zsh, an Alpine image with no bash. The test suite stays zsh; it runs where
# scalpel is developed, not where it is installed.
set -e

DIR="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$DIR/scalpel"
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
printf '\n'
cat "$DIR/claude-md-block.md"
printf '%s\n' "---------------------------------------------------------------"
