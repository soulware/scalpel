# scalpel

Batch exact-match edits to one file, applied atomically, with a version check
and diagnostics that say where a failed match nearly landed.

## Quickstart

```
git clone https://github.com/soulware/scalpel ~/src/scalpel
~/src/scalpel/install.sh
scalpel --version
```

The clone is the install: `install.sh` symlinks into it, so put it somewhere
that stays. Then paste the block it prints into `~/.claude/CLAUDE.md`. Details
under [Install](#install).

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
scalpel read FILE [--lines A-B,C-D,...]          hash, then numbered content
scalpel digest FILE                              the hash alone
scalpel edit FILE --expect-hash H [--dry-run]    edits as JSON on stdin
scalpel edit FILE --unchecked                    the same, with no version check
```

```console
$ scalpel read src/parser.rs --lines 1-3,44
# scalpel 4f3a9c2b1e8d src/parser.rs
 1	use std::fmt;
 2	
 3	pub struct Parser {
44	fn parse(input: &str) -> Result<Ast> {

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

The hash is demanded, not merely accepted. An `edit` with neither
`--expect-hash` nor `--unchecked` is refused before it reads its input, because
an optional check is one that gets skipped: across the same transcripts, two
scalpel edits in three ran without one. `--unchecked` waives it as a flag, so a
write that could not have noticed a changed file is visible as a choice rather
than an omission. Every successful edit prints the new hash on its last line,
so a run of edits to one file chains without another read. `--dry-run` needs
no hash, since it writes nothing.

Each edit is an object with `old` and `new`, and optionally `replace_all`.
`old` must appear exactly once unless `replace_all` is set. A bare object is
accepted in place of a one-element array. The four other ways of saying where
-- a range between two anchors, an insert beside one, append, prepend -- each
get a section below.

`read --lines` takes any number of windows -- `A-B`, a bare `N`, or `N-` to
the end -- and prints them in order under one hash. That is `sed -n
'A,Bp;C,Dp'` with the version token kept, which matters most on exactly the
files too long to read whole.

## Appending and prepending

Two positions need no anchor, because each names exactly one place by
construction: the end of the file and the start. An edit may carry `append` or
`prepend` in place of `old`/`new`, holding the text directly.

```console
$ scalpel edit tests/parser.rs --expect-hash 7d0c41e2b9a5 <<'EOF'
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
$ scalpel edit notes.md --expect-hash 3e8b1f6a2c47 <<'EOF'
[{"append": "one more line\n"}]
EOF
scalpel: edit 1: line 40 has no trailing newline before this point, so the text
  would continue it -- begin the text with a newline, or anchor an 'old'/'new'
  edit on that line
  nothing was written
```

A `prepend` whose text does not end in a newline is refused the same way, as is
LF text inserted into a CRLF file.

## Replacing a range

An `old` has to quote the whole of what it replaces. That is right for a line
or a hunk, and wrong for a sixty-line function whose head and tail you know and
whose body is the thing being thrown away: quoting it back costs the tokens the
edit was meant to save, and any drift in the middle is a failed match. `from`
names the start and `to` or `until` names the end.

```console
$ scalpel edit tests/parser.rs --expect-hash 7d0c41e2b9a5 <<'EOF'
[{"from": "    #[test]\n    fn parses_legacy_form",
  "until": "    #[test]\n    fn parses_nested_groups",
  "new": ""}]
EOF
scalpel: 1 edit applied to tests/parser.rs
  edit 1: lines 212-240 deleted
```

`from` obeys the same rule as `old`: it must appear exactly once. The end is
the first `to` or `until` after it, first rather than unique because "up to
the next test" is the idiom and the next test's header is never unique. `to`
keeps its anchor inside the range, so `"to": "\n}\n"` replaces through a
closing brace; `until` leaves it outside, so the next function's header stays.
An empty `new` deletes. The report gives the span in the numbering you read.

The end is searched only after `from`, so an anchor that also occurs earlier in
the file cannot produce a range running backwards; it is reported as not found.

## Inserting at an anchor

An insert with `old`/`new` repeats the anchor inside `new`, once to find the
place and once to keep it. `insert` carries the text and `before` or `after`
carries the anchor, which must appear exactly once.

```console
$ scalpel edit src/lib.rs --expect-hash c51a9e0d7b23 <<'EOF'
[{"insert": "mod parser;\n", "after": "mod lexer;\n"}]
EOF
scalpel: 1 edit applied to src/lib.rs
  edit 1: inserted 1 line after line 3
```

The text is whole lines. Both seams -- the join above the text and the join
below it -- must land on line boundaries, or the edit is refused with the same
message an `append` gives. An anchor that ends mid-line, `"after": "}"`, is
fine if the text begins with a newline. To splice into the middle of a line,
use `old`/`new`, which is what it is for.

## The last occurrence

The uniqueness rule has one honest exception. A tests module ends in a `}` that
has no distinguishing context at all except that it is the last one in the
file, and "the last one" is as definite a position as the end of the file is.
`last: true` on `old`, `from`, `before` or `after` selects the final match in
place of requiring a unique one.

```console
$ scalpel edit tests/parser.rs --expect-hash 7d0c41e2b9a5 <<'EOF'
[{"insert": "\n    #[test]\n    fn added() {\n        assert!(parse(\"a\").is_ok());\n    }\n",
  "before": "}\n", "last": true}]
EOF
scalpel: 1 edit applied to tests/parser.rs
  edit 1: inserted 5 lines before line 341 (last of 19)
```

The report says it chose, and out of how many, so a `last` that landed on the
wrong brace is visible in the output rather than in the compiler.

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

`edit` demands the hash rather than offering it, and `--unchecked` is the opt-out
for a file whose content you are creating yourself. The hash has to come from a
`read` you looked at before writing the edits, in an earlier call: that is what
proves the file is still the one you read. A `read` run in the same command as
the edit proves only that the file exists, which is `--unchecked` without the
flag. The check is the one guarantee here that you cannot reconstruct by being
careful.

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
$ scalpel edit config.py --expect-hash 5f2e8c1a9d04 <<'EOF'
[{"old": "timeout = 30", "new": "timeout = 60"}]
EOF
scalpel: edit 1: 'old' not found — matches at line 12 but the whitespace differs
  nothing was written

$ scalpel edit handler.py --expect-hash a97d3b4e6f18 <<'EOF'
[{"old": "return None", "new": "return []"}]
EOF
scalpel: edit 1: 'old' has 3 matches (lines 22, 47, 91) — add surrounding context, set "last": true, or set "replace_all": true
  nothing was written

$ scalpel edit win.txt --expect-hash 1b6c0d9f4e82 <<'EOF'
[{"old": "alpha\nbeta", "new": "gamma"}]
EOF
scalpel: edit 1: 'old' not found — file uses CRLF line endings, your text uses LF
  nothing was written
```

When none of the specific checks fire, it anchors on the first non-blank line of
your `old`, scores candidate windows, and prints the closest with a diff:

```
scalpel: edit 1: 'old' not found — closest match at line 88 (91% similar)
    @@ -1,2 +1,2 @@
    -def process(self, val):
    +def process(self, value):
```

Ambiguity, whitespace, and line endings are the three causes worth naming
specifically, because all three are invisible in a terminal and all three are
common. The fuzzy fallback catches the rest.

## Install

Needs python3, 3.7 or later, and git for `--version`. The tests need zsh.

```
git clone https://github.com/soulware/scalpel ~/src/scalpel
~/src/scalpel/install.sh
```

The clone is the install. `install.sh` symlinks `scalpel` into `~/.local/bin`
rather than copying it, so edits in the checkout take effect immediately -- and
so the checkout has to stay where it is. Clone it somewhere permanent, not a
scratch or temporary directory; a link into a directory that is later cleaned
up fails on every call. The script checks that `~/.local/bin` is on your `PATH`
and says so if not.

`scalpel --version` prints the short hash of the checkout the link points at,
with `-modified` appended if that checkout has uncommitted changes.

For Claude Code to reach for it, it has to know it exists. `install.sh` prints a
block for your global `~/.claude/CLAUDE.md` and writes nothing there itself. It
is printed so that a person can read it before it goes in; a Claude session
installing scalpel for its user should show the block, then add it to that file
with their agreement.

## Limits

**The version check is its own.** Claude Code's builtin tools maintain their
own read-before-write state and refuse an `Edit` to a file modified since the
last `Read`. scalpel is a shell command, so `--expect-hash` carries that
guarantee itself, and `edit` demands it rather than offering it, which is why
`read` emits the hash rather than making you ask. `--unchecked` is the
opt-out, and it is a flag so that it shows in review.

**Review reads JSON.** A builtin `Edit` renders as a diff in the transcript; a
scalpel call renders as the JSON it was given. That is a real loss, and the
CLAUDE.md block still says scalpel for every edit, because a threshold is a
decision on every edit, and a session that gets it wrong falls back to `sed -i`
rather than to `Edit`. `--dry-run` prints a unified diff when the review
matters.

**One file per call.** A cross-file rename is a script of calls, one hash each.

**Existing files only.** `edit` on a missing path is an error. Create the file
with a heredoc or Write; a new file has nothing to batch and nothing yet to
check.

## Tests

```
./test.sh
```

No dependencies beyond zsh and python3. The checks that matter are the negative
ones — nothing was written, the edit was refused, the mode was preserved —
because those are the claims that rot without anyone noticing.

## Licence

MIT or Apache-2.0, at your option.
