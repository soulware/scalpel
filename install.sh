#!/bin/zsh
# Link scalpel onto your PATH.
#
# Nothing here writes to ~/.claude. Telling Claude Code that scalpel exists is a
# change to your CLAUDE.md, and that is yours to make — the block to paste is
# printed at the end.
set -e

SRC="${0:A:h}/scalpel"
BIN="$HOME/.local/bin"

if ! command -v python3 > /dev/null; then
  print -r -- "scalpel needs python3." >&2
  exit 1
fi

mkdir -p "$BIN"
chmod +x "$SRC"

# Linked, not copied, so edits in this repo take effect on the next call. A
# stale copy that silently diverges from the repo is the failure worth avoiding.
ln -sf "$SRC" "$BIN/scalpel"
print -r -- "linked $BIN/scalpel -> $SRC"

# A link onto a directory that is not on PATH installs cleanly and then is never
# found, which reads as "the tool is broken" rather than "the shell cannot see
# it". Say which one it is.
if [[ ":$PATH:" != *":$BIN:"* ]]; then
  print -r -- ""
  print -r -- "warning: $BIN is not on your PATH."
  print -r -- "add this to your ~/.zshrc:"
  print -r -- ""
  print -r -- "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

print -r -- ""
print -r -- "--- paste into CLAUDE.md ---------------------------------------"
cat <<'BLOCK'

## Editing files

`scalpel` batches exact-match edits into one atomic call. Prefer it over the
builtin Edit tool when making three or more changes to the same file, and over
`sed -i` always.

    scalpel read FILE [--lines A-B,C-D]   # prints "# scalpel <hash> FILE", then content
    scalpel edit FILE --expect-hash <hash> <<'EOF'
    [{"old": "...", "new": "..."},
     {"old": "...", "new": "...", "replace_all": true},
     {"from": "start anchor", "until": "end anchor", "new": ""},
     {"insert": "text\n", "after": "anchor\n"},
     {"insert": "text\n", "before": "}\n", "last": true},
     {"append": "text\n"}]
    EOF

Pass `--expect-hash` with the hash from `scalpel read`. The edit is refused
(exit 3) if anything wrote the file in between. All edits apply or none do; a
failed batch writes nothing and names the line where the match nearly landed.
Use `--dry-run` to see a diff without writing.

`from`/`to`/`until` replaces a range without quoting its body; `insert` with
`before`/`after` adds whole lines beside an anchor; `last: true` picks the
final occurrence where the file has no unique context. `scalpel edit --help`
carries the full format.

For one or two edits, the builtin Edit tool renders a better diff in review.
BLOCK
print -r -- "---------------------------------------------------------------"
