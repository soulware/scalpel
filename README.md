# scalpel

Batch exact-match edits to one file, applied atomically, with a version check
and diagnostics that say where a failed match nearly landed.

## Why

Claude Code's builtin `Edit` tool takes one `old_string`, requires it to be
unique in the file, and applies one change per call. Both properties are
deliberate and both are load-bearing: uniqueness means a match proves you knew
the file's contents, and one-at-a-time means a failure never leaves a file
half-rewritten.

They also have a measurable cost. Across 101 local transcripts:

```
Edit calls                                    2295
  in runs of >=2 to the same file       1755 (76%)
  distinct runs                                967
  longest single run                            32
```

Collapsing each run into one call would be 967 calls instead of 2295 — 1328
round trips saved, 58%. The same transcripts show `old_string` at a median of
217 characters and a mean of 381, totalling 875 KB across all edits. Most of
that is not the change; it is surrounding context quoted only to make the match
unique. Roughly 220K tokens spent saying *where*.

The workaround people reach for is a shell rewrite, and the same transcripts
show it: 734 heredoc writes, 45 `sed -i`, 84 `perl -pi`, against 398 calls to
the `Write` tool. That trade is worse than it looks. `sed -i` succeeds on a file
that changed since you read it, succeeds when its pattern matched the wrong
place, and succeeds when it matched nothing at all. Every safety property the
builtin tools have is discarded to save a round trip.

scalpel is the middle: batch the calls, keep the properties.

## Use

```
scalpel read FILE [--offset N] [--limit N]     hash, then numbered content
scalpel digest FILE                            the hash alone
scalpel edit FILE [--expect-hash H] [--dry-run]  edits as JSON on stdin
```

```console
$ scalpel read src/parser.rs --limit 3
# scalpel 4f3a9c2b1e8d src/parser.rs
1	use std::fmt;
2	
3	pub struct Parser {

$ scalpel edit src/parser.rs --expect-hash 4f3a9c2b1e8d <<'EOF'
[{"old": "fn parse(", "new": "fn parse_expr("},
 {"old": "// TODO: handle nesting", "new": "// handled below"},
 {"old": "debug!(", "new": "trace!(", "replace_all": true}]
EOF
scalpel: 3 edits applied to src/parser.rs
  edit 1: line 44
  edit 2: line 91
  edit 3: 4 replacements (lines 12, 58, 103, 140)
# scalpel 9b2e77c04a1f src/parser.rs
```

Each edit is an object with `old` and `new`, and optionally `replace_all`.
`old` must appear exactly once unless `replace_all` is set. A bare object is
accepted in place of a one-element array.

## Appending and prepending

Two positions need no anchor, because each names exactly one place by
construction: the end of the file and the start. An edit may carry `append` or
`prepend` in place of `old`/`new`, holding the text directly.

```console
$ scalpel edit tests/parser.rs <<'EOF'
[{"append": "\n#[test]\nfn parses_nested_groups() {\n    assert!(parse(\"((a))\").is_ok());\n}\n"}]
EOF
scalpel: 1 edit applied to tests/parser.rs
  edit 1: appended 5 lines at line 341
```

This is the one position anchoring is genuinely bad at. A file whose last line
is `}` has no unique tail, so the anchor must widen until it has one: across the
same transcripts, inserts that anchored at EOF carried a median of 165
characters of `old` to say nothing but *at the end*, and 25 further appends gave
up and went to `cat >>`, discarding the version check to save the trouble.
Naming the position costs neither.

No newline is guessed for you. The text goes in byte for byte, exactly as `old`
is matched byte for byte, so an `append` carries its own trailing newline — and
its own blank separator line, if it wants one. What cannot be guessed is refused
instead, because each of these welds two lines together and then looks like
success:

```console
$ scalpel edit notes.md <<'EOF'
[{"append": "one more line\n"}]
EOF
scalpel: edit 1: the file has no trailing newline, so this would continue line 40
  -- begin the text with a newline, or anchor an 'old'/'new' edit on that line
  nothing was written
```

A `prepend` whose text does not end in a newline is refused the same way, as is
LF text inserted into a CRLF file.

## The three properties

**Atomic.** Edits are applied to an in-memory buffer and the file is written
once, at the end, through a temp file in the same directory and `os.replace`.
If edit 7 of 9 fails, nothing is written at all. This is the property a `sed`
loop cannot have, and it is why the tool exists rather than a shell function.

**Sequential.** A later edit sees what an earlier one wrote, matching what you
get editing one hunk at a time. Edits that overlap therefore behave predictably
instead of racing.

**Versioned.** `read` prints a content hash; `edit --expect-hash` refuses if the
file no longer hashes to it, and exits 3. That is compare-and-swap, and it is
the thing shell rewrites throw away. The file can move underneath you between
your read and your write — you fixed a typo in your editor, a formatter ran on
save, a hook fired, another session was in the same directory — and without the
check that change is silently discarded.

The check is optional, because sometimes you genuinely are creating the content
you are about to match. But omitting it forfeits the only guarantee here that
you cannot reconstruct by being careful.

The hash is the first 12 characters of a SHA-256, because what it guards against
is a file changing by accident — an editor, a formatter on save, another session
— rather than an adversary constructing a collision. 48 bits is one in 2.8e14
against accident, well past the point where more characters buy anything, and
the full 64 would be printed once and typed back once on every edit. A longer
prefix is still accepted, so a full digest from `sha256sum` also works.

## Diagnostics

The reason to prefer a tool over `sed -i` is what happens when the match fails.
`sed` tells you nothing; a bare "string not found" costs a re-read to resolve.

```console
$ scalpel edit config.py <<'EOF'
[{"old": "timeout = 30", "new": "timeout = 60"}]
EOF
scalpel: edit 1: not found — matches at line 12 but the whitespace differs
  nothing was written

$ scalpel edit handler.py <<'EOF'
[{"old": "return None", "new": "return []"}]
EOF
scalpel: edit 1: 3 matches (lines 22, 47, 91) — add surrounding context, or set "replace_all": true
  nothing was written

$ scalpel edit win.txt <<'EOF'
[{"old": "alpha\nbeta", "new": "gamma"}]
EOF
scalpel: edit 1: not found — file uses CRLF line endings, your old text uses LF
  nothing was written
```

When none of the specific checks fire, it anchors on the first non-blank line of
your `old`, scores candidate windows, and prints the closest with a diff:

```
scalpel: edit 1: not found — closest match at line 88 (91% similar)
    @@ -1,2 +1,2 @@
    -def process(self, val):
    +def process(self, value):
```

Ambiguity, whitespace, and line endings are the three causes worth naming
specifically, because all three are invisible in a terminal and all three are
common. The fuzzy fallback catches the rest.

## Install

```
./install.sh
```

Symlinks `scalpel` into `~/.local/bin`, so edits in this repo take effect
immediately. It checks that the directory is on your `PATH` and says so if not.

For Claude Code to reach for it, it has to know it exists. `install.sh` prints a
block to paste into your `CLAUDE.md`; nothing is written to your config
automatically.

## What this does not do

**It is outside the harness's file tracking.** Claude Code's builtin tools
maintain their own read-before-write state and will refuse an `Edit` to a file
modified since the last `Read`. scalpel is a shell command and gets none of
that. `--expect-hash` reconstructs the guarantee, but only if you pass it, which
is why `read` emits the hash rather than making you ask.

**Your diff review is worse.** A builtin `Edit` renders as a diff in the
transcript. A scalpel call renders as a JSON blob. That is a real loss, and it
argues for using the builtin for short runs and scalpel only when the batch is
long enough to pay for it. On the numbers above, that is about a quarter of
runs.

**It is one file per call.** Cross-file renames are still a script.

**It will not create files.** `edit` on a missing path is an error, not a
create. Use a heredoc; there is nothing to batch and nothing to verify.

## Tests

```
./test.sh
```

No dependencies beyond zsh and python3. The checks that matter are the negative
ones — nothing was written, the edit was refused, the mode was preserved —
because those are the claims that rot without anyone noticing.

## Licence

MIT or Apache-2.0, at your option.
