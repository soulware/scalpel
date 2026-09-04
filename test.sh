#!/bin/zsh
# scalpel's test suite. Run it from anywhere: ./test.sh
#
# Every claim the README makes is checked here, because the ones that matter
# are all negative claims — nothing was written, the edit was refused — and a
# negative claim is exactly the kind that rots silently.
set -u

SCALPEL="${0:A:h}/scalpel"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { print -r -- "  ok   $1"; ((pass++)); }
no() { print -r -- "  FAIL $1"; print -r -- "       $2"; ((fail++)); }

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$name"; else
    no "$name" "want: ${(qqq)want}
       got:  ${(qqq)got}"
  fi
}

fixture() {
  local f="$WORK/$1"
  shift
  print -rn -- "$1" > "$f"
  print -r -- "$f"
}

print -r -- "scalpel tests"
print -r -- ""

# --- basic application -------------------------------------------------------
print -r -- "applying edits"

f=$(fixture a.txt 'alpha
beta
gamma
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "beta", "new": "BETA"}]
EOF
check "single edit applies" 'alpha
BETA
gamma' "$(cat "$f")"

f=$(fixture b.txt 'one
two
three
four
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "one", "new": "1"},
 {"old": "three", "new": "3"},
 {"old": "four", "new": "4"}]
EOF
check "three edits in one call" '1
two
3
4' "$(cat "$f")"

# A later edit must see what an earlier one wrote, or the semantics differ
# from editing one hunk at a time and callers will be surprised.
f=$(fixture seq.txt 'x
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "x", "new": "y"},
 {"old": "y", "new": "z"}]
EOF
check "edits apply sequentially" 'z' "$(cat "$f")"

f=$(fixture all.txt 'dup
keep
dup
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "dup", "new": "D", "replace_all": true}]
EOF
check "replace_all replaces every match" 'D
keep
D' "$(cat "$f")"

# --- atomicity ---------------------------------------------------------------
print -r -- ""
print -r -- "atomicity"

# The load-bearing test. Edit 1 is valid, edit 2 is not. If the file comes back
# with "one" rewritten, the batch was not atomic and the tool is worse than sed.
f=$(fixture atomic.txt 'one
two
')
before=$(cat "$f")
"$SCALPEL" edit "$f" > /dev/null 2>&1 <<'EOF'
[{"old": "one", "new": "1"},
 {"old": "nonexistent", "new": "x"}]
EOF
rc=$?
check "failed batch writes nothing" "$before" "$(cat "$f")"
[[ $rc -ne 0 ]] && ok "failed batch exits non-zero" \
                || no "failed batch exits non-zero" "exit was 0"

# --- the version check -------------------------------------------------------
print -r -- ""
print -r -- "compare-and-swap"

f=$(fixture cas.txt 'original
')
h=$("$SCALPEL" digest "$f")
"$SCALPEL" edit "$f" --expect-hash "$h" > /dev/null <<'EOF'
[{"old": "original", "new": "edited"}]
EOF
check "correct hash is accepted" 'edited' "$(cat "$f")"

f=$(fixture len.txt 'x
')
h=$("$SCALPEL" digest "$f")
check "hash is 12 characters" "12" "${#h}"

# A longer prefix has to keep working, so a full digest from sha256sum, or one
# taken before the hash was shortened, is still a usable token.
f=$(fixture caslong.txt 'original
')
full=$(shasum -a 256 "$f" | cut -d' ' -f1)
"$SCALPEL" edit "$f" --expect-hash "$full" > /dev/null <<'EOF'
[{"old": "original", "new": "edited"}]
EOF
check "full-length hash is accepted" 'edited' "$(cat "$f")"

# Short enough to collide by accident is worse than no check, because it reads
# as one.
f=$(fixture casshort.txt 'original
')
out=$("$SCALPEL" edit "$f" --expect-hash abc 2>&1 <<'EOF'
[{"old": "original", "new": "edited"}]
EOF
)
[[ $? -ne 0 && "$out" == *"at least 8 hex"* ]] \
  && ok "too-short hash is refused" || no "too-short hash is refused" "$out"

f=$(fixture casjunk.txt 'original
')
out=$("$SCALPEL" edit "$f" --expect-hash "not-a-hex-string" 2>&1 <<'EOF'
[{"old": "original", "new": "edited"}]
EOF
)
[[ $? -ne 0 && "$out" == *"hex"* ]] \
  && ok "non-hex hash is refused" || no "non-hex hash is refused" "$out"

f=$(fixture stale.txt 'original
')
h=$("$SCALPEL" digest "$f")
print -rn -- 'somebody else wrote this
' > "$f"          # the linter, the user, another session
out=$("$SCALPEL" edit "$f" --expect-hash "$h" 2>&1 <<'EOF'
[{"old": "somebody", "new": "nobody"}]
EOF
)
rc=$?
check "stale hash leaves file alone" 'somebody else wrote this' "$(cat "$f")"
[[ $rc -eq 3 ]] && ok "stale hash exits 3" || no "stale hash exits 3" "exit was $rc"
[[ "$out" == *"changed since you read it"* ]] \
  && ok "stale hash explains itself" \
  || no "stale hash explains itself" "$out"

# `read` must emit the same digest `edit` will demand, or the pairing is broken.
f=$(fixture pair.txt 'content
')
rh=$("$SCALPEL" read "$f" | head -1 | awk '{print $3}')
hh=$("$SCALPEL" digest "$f")
check "read and digest agree" "$hh" "$rh"

# --- diagnostics -------------------------------------------------------------
print -r -- ""
print -r -- "near-miss diagnostics"

# Indentation has to differ *inside* a multi-line match to be interesting. A
# single line with different leading space is still a plain substring hit, and
# should stay one — that is what the builtin Edit does too.
f=$(fixture ws.txt 'def f():
        return 1
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "def f():\n    return 1", "new": "def f():\n    return 2"}]
EOF
)
[[ "$out" == *"whitespace differs"* && "$out" == *"line 1"* ]] \
  && ok "whitespace mismatch names the line" \
  || no "whitespace mismatch names the line" "$out"

f=$(fixture ws2.txt '    indented line
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "indented line", "new": "x"}]
EOF
check "leading space is still a substring match" '    x' "$(cat "$f")"

f=$(fixture amb.txt 'return None
return None
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "return None", "new": "return 0"}]
EOF
)
[[ "$out" == *"2 matches"* && "$out" == *"lines 1, 2"* ]] \
  && ok "ambiguity lists every line" \
  || no "ambiguity lists every line" "$out"

f=$(fixture crlf.txt $'alpha\r\nbeta\r\n')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "alpha\nbeta", "new": "x"}]
EOF
)
[[ "$out" == *"CRLF"* ]] \
  && ok "CRLF mismatch is named" \
  || no "CRLF mismatch is named" "$out"

f=$(fixture near.txt 'def process(self, value):
    return value * 2
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "def process(self, val):", "new": "def process(self, v):"}]
EOF
)
[[ "$out" == *"closest match at line 1"* ]] \
  && ok "fuzzy near-miss names the line" \
  || no "fuzzy near-miss names the line" "$out"

f=$(fixture none.txt 'completely unrelated
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "zzzzz qqqqq", "new": "x"}]
EOF
)
[[ "$out" == *"not found"* ]] \
  && ok "genuine miss says not found" \
  || no "genuine miss says not found" "$out"

# --- file properties ---------------------------------------------------------
print -r -- ""
print -r -- "preserving the file"

f=$(fixture keepcrlf.txt $'alpha\r\nbeta\r\n')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "alpha", "new": "ALPHA"}]
EOF
if [[ -n "$(tr -d '\0' < "$f" | grep -c $'\r')" ]] && od -c < "$f" | grep -q '\\r'; then
  ok "CRLF endings survive an edit"
else
  no "CRLF endings survive an edit" "$(od -c < "$f" | head -2)"
fi

f=$(fixture nonewline.txt 'no trailing newline')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "no trailing", "new": "still no trailing"}]
EOF
[[ "$(od -c < "$f" | tail -2 | head -1)" != *'\n'* ]] \
  && ok "missing trailing newline is not added" \
  || no "missing trailing newline is not added" "$(od -c < "$f" | tail -2)"

f=$(fixture perms.sh 'echo hi
')
chmod 755 "$f"
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"old": "hi", "new": "bye"}]
EOF
check "file mode is preserved" "755" "$(stat -f '%Lp' "$f")"

# --- dry run -----------------------------------------------------------------
print -r -- ""
print -r -- "dry run"

f=$(fixture dry.txt 'before
')
out=$("$SCALPEL" edit "$f" --dry-run 2>/dev/null <<'EOF'
[{"old": "before", "new": "after"}]
EOF
)
check "dry run writes nothing" 'before' "$(cat "$f")"
[[ "$out" == *"-before"* && "$out" == *"+after"* ]] \
  && ok "dry run prints a diff" \
  || no "dry run prints a diff" "$out"

# --- anchorless inserts ------------------------------------------------------
print -r -- ""
print -r -- "appending and prepending"

f=$(fixture app.txt 'alpha
beta
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "gamma\n"}]
EOF
check "append lands at the end" 'alpha
beta
gamma' "$(cat "$f")"

f=$(fixture pre.txt 'alpha
beta
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"prepend": "# header\n"}]
EOF
check "prepend lands at the start" '# header
alpha
beta' "$(cat "$f")"

# Inserts are edits like any other: they take their turn in the batch and the
# buffer they see is whatever the edits before them left.
f=$(fixture mix.txt 'alpha
beta
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"prepend": "# top\n"}, {"old": "beta", "new": "BETA"}, {"append": "delta\n"}]
EOF
check "inserts and replacements share one batch" '# top
alpha
BETA
delta' "$(cat "$f")"

f=$(fixture stack.txt 'one
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "two\n"}, {"append": "three\n"}]
EOF
check "two appends stack in order" 'one
two
three' "$(cat "$f")"

f=$(fixture empty.txt '')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "first\n"}]
EOF
check "append to an empty file" 'first' "$(cat "$f")"

# Byte for byte: an append that omits its own newline gets no newline invented
# for it, exactly as `old`/`new` text is taken literally.
f=$(fixture exact.txt 'a
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "b"}]
EOF
check "no newline is invented" $'a\nb' "$(cat "$f")"

# A failed insert must leave the file alone like any other failed edit.
f=$(fixture atomic-ins.txt 'keep
')
"$SCALPEL" edit "$f" > /dev/null 2>&1 <<'EOF'
[{"append": "added\n"}, {"old": "absent", "new": "x"}]
EOF
check "a later failure discards the append" 'keep' "$(cat "$f")"

# --- insert seams ------------------------------------------------------------
print -r -- ""
print -r -- "refusing a seam that would corrupt"

# The whole point of naming a position instead of quoting one is that it cannot
# land in the wrong place. The one thing it cannot see is the join, so a join
# that would silently weld two lines together is refused instead.
f=$(fixture nonl.txt 'alpha
beta')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": "gamma\n"}]
EOF
)
[[ $? -ne 0 && "$out" == *"no trailing newline"* ]] \
  && ok "append onto an unterminated last line is refused" \
  || no "append onto an unterminated last line is refused" "$out"
check "  ...and nothing was written" 'alpha
beta' "$(cat "$f")"

"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "\ngamma\n"}]
EOF
check "  ...and the suggested fix works" 'alpha
beta
gamma' "$(cat "$f")"

f=$(fixture prenl.txt 'alpha
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"prepend": "# header"}]
EOF
)
[[ $? -ne 0 && "$out" == *"no trailing newline"* ]] \
  && ok "prepend that would run into line 1 is refused" \
  || no "prepend that would run into line 1 is refused" "$out"

f=$(fixture crlf-ins.txt $'a\r\nb\r\n')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": "c\n"}]
EOF
)
[[ $? -ne 0 && "$out" == *"CRLF"* ]] \
  && ok "LF text appended to a CRLF file is refused" \
  || no "LF text appended to a CRLF file is refused" "$out"

"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"append": "c\r\n"}]
EOF
# Compared as bytes: command substitution eats the trailing newline but leaves
# the carriage return, so a plain string compare here would lie.
check "  ...CRLF text is accepted" \
  "$(printf 'a\r\nb\r\nc\r\n' | od -c)" "$(od -c < "$f")"

# --- input validation --------------------------------------------------------
print -r -- ""
print -r -- "rejecting bad input"

f=$(fixture bad.txt 'x
')
out=$("$SCALPEL" edit "$f" 2>&1 <<<'not json')
[[ $? -ne 0 && "$out" == *"not valid JSON"* ]] \
  && ok "invalid JSON is refused" || no "invalid JSON is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "x"}]
EOF
)
[[ $? -ne 0 && "$out" == *"identical"* ]] \
  && ok "no-op edit is refused" || no "no-op edit is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "", "new": "y"}]
EOF
)
[[ $? -ne 0 && "$out" == *"empty"* ]] \
  && ok "empty old is refused" || no "empty old is refused" "$out"

out=$("$SCALPEL" edit "$WORK/missing.txt" 2>&1 <<'EOF'
[{"old": "a", "new": "b"}]
EOF
)
[[ $? -ne 0 && "$out" == *"no such file"* ]] \
  && ok "missing file is refused" || no "missing file is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "y", "append": "z\n"}]
EOF
)
[[ $? -ne 0 && "$out" == *"exactly one of"* ]] \
  && ok "two ways of saying where is refused" \
  || no "two ways of saying where is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"new": "y"}]
EOF
)
[[ $? -ne 0 && "$out" == *"exactly one of"* ]] \
  && ok "no way of saying where is refused" \
  || no "no way of saying where is refused" "$out"

# A typo'd key would otherwise be ignored, and `untill` or `lsat` ignored is a
# different edit from the one asked for.
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "y", "lsat": true}]
EOF
)
[[ $? -ne 0 && "$out" == *"unknown key 'lsat'"* ]] \
  && ok "unknown key is refused" || no "unknown key is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": ""}]
EOF
)
[[ $? -ne 0 && "$out" == *"empty"* ]] \
  && ok "empty append is refused" || no "empty append is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": "y\n", "new": "z"}]
EOF
)
[[ $? -ne 0 && "$out" == *"no 'new'"* ]] \
  && ok "append with a 'new' is refused" || no "append with a 'new' is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": "y\n", "replace_all": true}]
EOF
)
[[ $? -ne 0 && "$out" == *"means nothing"* ]] \
  && ok "replace_all on an append is refused" \
  || no "replace_all on an append is refused" "$out"

# --- read windows -----------------------------------------------------------
print -r -- ""
print -r -- "reading windows"

f=$(fixture win.txt 'l1
l2
l3
l4
l5
l6
l7
l8
l9
l10
')
out=$("$SCALPEL" read "$f" --lines 2-3,9-10 | tail -n +2)
check "several windows in one call" $' 2\tl2\n 3\tl3\n 9\tl9\n10\tl10' "$out"

out=$("$SCALPEL" read "$f" --lines 4 | tail -n +2)
check "a bare number is one line" $'4\tl4' "$out"

out=$("$SCALPEL" read "$f" --lines 9- | tail -n +2)
check "an open range runs to the end" $' 9\tl9\n10\tl10' "$out"

# A trailing newline is not an eleventh empty line.
check "read does not invent a trailing empty line" "10" "$("$SCALPEL" read "$f" | tail -n +2 | wc -l | tr -d ' ')"

out=$("$SCALPEL" read "$f" --lines 50-60 2>&1 >/dev/null)
[[ "$out" == *"past the end"* ]] \
  && ok "a window past the end says so" || no "a window past the end says so" "$out"

out=$("$SCALPEL" read "$f" --lines 5-2 2>&1 >/dev/null)
[[ $? -ne 0 && "$out" == *"not a valid range"* ]] \
  && ok "a backwards range is refused" || no "a backwards range is refused" "$out"

# The hash on a windowed read must be the hash of the whole file, or the
# pairing with --expect-hash breaks exactly when the file is big enough to
# want windows.
rh=$("$SCALPEL" read "$f" --lines 2-3 | head -1 | awk '{print $3}')
check "windowed read hashes the whole file" "$("$SCALPEL" digest "$f")" "$rh"

# --- range replace -----------------------------------------------------------
print -r -- ""
print -r -- "replacing a range"

RUST='mod tests {
    #[test]
    fn keep() {
        assert!(true);
    }

    #[test]
    fn drop_me() {
        let x = 1;
        assert_eq!(x, 1);
    }

    #[test]
    fn also_keep() {
        assert!(true);
    }
}
'

f=$(fixture until.rs "$RUST")
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"from": "    #[test]\n    fn drop_me", "until": "    #[test]\n    fn also_keep", "new": ""}]
EOF
)
check "until deletes up to its anchor" 'mod tests {
    #[test]
    fn keep() {
        assert!(true);
    }

    #[test]
    fn also_keep() {
        assert!(true);
    }
}' "$(cat "$f")"
[[ "$out" == *"lines 7-12 deleted"* ]] \
  && ok "  ...and reports the span" || no "  ...and reports the span" "$out"

f=$(fixture to.rs "$RUST")
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"from": "    fn drop_me() {", "to": "\n    }\n", "new": "    fn renamed() {\n        todo!()\n    }\n"}]
EOF
)
check "to replaces through its anchor" 'mod tests {
    #[test]
    fn keep() {
        assert!(true);
    }

    #[test]
    fn renamed() {
        todo!()
    }

    #[test]
    fn also_keep() {
        assert!(true);
    }
}' "$(cat "$f")"
[[ "$out" == *"lines 8-11 replaced"* ]] \
  && ok "  ...and reports the span" || no "  ...and reports the span" "$out"

# `from` obeys the uniqueness rule; only the end anchor takes the first hit.
f=$(fixture amb-from.rs "$RUST")
before=$(cat "$f")
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"from": "    #[test]\n", "until": "}\n", "new": ""}]
EOF
)
[[ $? -eq 2 && "$out" == *"'from' has 3 matches"* ]] \
  && ok "ambiguous from is refused" || no "ambiguous from is refused" "$out"
check "  ...and nothing was written" "$before" "$(cat "$f")"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"from": "    fn drop_me() {", "until": "    fn never_here", "new": ""}]
EOF
)
[[ $? -eq 2 && "$out" == *"'until' not found after 'from' (line 8)"* ]] \
  && ok "missing end anchor names the from line" \
  || no "missing end anchor names the from line" "$out"

# The end is searched only after `from`, so an anchor that also appears
# earlier in the file cannot produce a backwards range.
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"from": "    fn also_keep() {", "until": "    fn keep() {", "new": ""}]
EOF
)
[[ $? -eq 2 && "$out" == *"not found after 'from'"* ]] \
  && ok "end anchor before from does not count" \
  || no "end anchor before from does not count" "$out"
check "  ...and nothing was written" "$before" "$(cat "$f")"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"from": "    fn drop_me() {", "new": ""}]
EOF
)
[[ $? -ne 0 && "$out" == *"exactly one of 'to', 'until'"* ]] \
  && ok "from without an end is refused" || no "from without an end is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"from": "    fn drop_me() {", "to": "\n    }\n", "new": "    fn drop_me() {\n        let x = 1;\n        assert_eq!(x, 1);\n    }\n"}]
EOF
)
[[ $? -eq 2 && "$out" == *"already reads as 'new'"* ]] \
  && ok "no-op range is refused" || no "no-op range is refused" "$out"

f=$(fixture atomic-range.rs "$RUST")
"$SCALPEL" edit "$f" > /dev/null 2>&1 <<'EOF'
[{"from": "    fn drop_me() {", "to": "\n    }\n", "new": ""},
 {"old": "absent", "new": "x"}]
EOF
check "a later failure discards the range edit" "$RUST" "$(cat "$f")"$'\n'

# --- anchored insert ---------------------------------------------------------
print -r -- ""
print -r -- "inserting at an anchor"

f=$(fixture ins.txt 'alpha
beta
gamma
')
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"insert": "one\n", "before": "beta\n"},
 {"insert": "two\n", "after": "beta\n"}]
EOF
)
check "insert before and after an anchor" 'alpha
one
beta
two
gamma' "$(cat "$f")"
[[ "$out" == *"inserted 1 line before line 2"* \
   && "$out" == *"inserted 1 line after line 3"* ]] \
  && ok "  ...and reports both positions" || no "  ...and reports both positions" "$out"

# The anchor is not repeated in the text, so it must not be consumed either.
f=$(fixture ins-keep.txt 'x
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"insert": "y\n", "after": "x\n"}]
EOF
check "the anchor survives the insert" 'x
y' "$(cat "$f")"

f=$(fixture ins-amb.txt 'a
b
a
')
before=$(cat "$f")
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "c\n", "before": "a\n"}]
EOF
)
[[ $? -eq 2 && "$out" == *"'before' has 2 matches"* ]] \
  && ok "ambiguous anchor is refused" || no "ambiguous anchor is refused" "$out"
check "  ...and nothing was written" "$before" "$(cat "$f")"

# Both seams. Text that does not end in a newline would run into the anchor
# line; an anchor that ends mid-line would be continued by the text.
f=$(fixture ins-seam.txt 'alpha
beta
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "x", "before": "beta"}]
EOF
)
[[ $? -eq 2 && "$out" == *"run into line 2"* ]] \
  && ok "insert running into the anchor line is refused" \
  || no "insert running into the anchor line is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "x\n", "after": "alp"}]
EOF
)
[[ $? -eq 2 && "$out" == *"continue"* && "$out" == *"line 1"* ]] \
  && ok "insert continuing the anchor line is refused" \
  || no "insert continuing the anchor line is refused" "$out"
check "  ...and nothing was written" 'alpha
beta' "$(cat "$f")"

# A leading newline is how the text asks to start a fresh line after an anchor
# that ends mid-line: `after: "}"` with `insert: "\nfn f() {}"`.
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"insert": "\nmid", "after": "alpha"}]
EOF
check "a leading newline satisfies the left seam" 'alpha
mid
beta' "$(cat "$f")"

f=$(fixture ins-crlf.txt $'a\r\nb\r\n')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "c\n", "before": "b\r\n"}]
EOF
)
[[ $? -eq 2 && "$out" == *"CRLF"* ]] \
  && ok "LF text inserted into a CRLF file is refused" \
  || no "LF text inserted into a CRLF file is refused" "$out"

f=$(fixture ins-bad.txt 'x
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "y\n"}]
EOF
)
[[ $? -ne 0 && "$out" == *"exactly one of 'before', 'after'"* ]] \
  && ok "insert without an anchor is refused" \
  || no "insert without an anchor is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "y\n", "before": "x", "after": "x"}]
EOF
)
[[ $? -ne 0 && "$out" == *"exactly one of 'before', 'after'"* ]] \
  && ok "insert with two anchors is refused" \
  || no "insert with two anchors is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"insert": "y\n", "before": "x", "new": "z"}]
EOF
)
[[ $? -ne 0 && "$out" == *"no 'new'"* ]] \
  && ok "insert with a 'new' is refused" || no "insert with a 'new' is refused" "$out"

f=$(fixture atomic-ins2.txt 'keep
')
"$SCALPEL" edit "$f" > /dev/null 2>&1 <<'EOF'
[{"insert": "added\n", "before": "keep\n"}, {"old": "absent", "new": "x"}]
EOF
check "a later failure discards the insert" 'keep' "$(cat "$f")"

# --- last --------------------------------------------------------------------
print -r -- ""
print -r -- "last: true"

# The motivating case: a tests module whose only distinguishing feature is
# that its closing brace comes last.
f=$(fixture last.rs 'fn a() {
}

mod tests {
    fn t() {
    }
}
')
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"insert": "    fn added() {\n    }\n", "before": "}\n", "last": true}]
EOF
)
check "last picks the final anchor for an insert" 'fn a() {
}

mod tests {
    fn t() {
    }
    fn added() {
    }
}' "$(cat "$f")"
[[ "$out" == *"inserted 2 lines before line 7 (last of 3)"* ]] \
  && ok "  ...and says it chose the last of several" \
  || no "  ...and says it chose the last of several" "$out"

f=$(fixture last-old.txt 'x
x
x
')
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"old": "x", "new": "y", "last": true}]
EOF
)
check "last on old replaces only the final match" 'x
x
y' "$(cat "$f")"
[[ "$out" == *"line 3 (last of 3)"* ]] \
  && ok "  ...and reports the line" || no "  ...and reports the line" "$out"

f=$(fixture last-from.txt 'BEGIN
one
END
BEGIN
two
END
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"from": "BEGIN\n", "to": "END\n", "new": "", "last": true}]
EOF
check "last on from ranges from the final start" 'BEGIN
one
END' "$(cat "$f")"

f=$(fixture last-after.txt 'a
b
a
')
"$SCALPEL" edit "$f" > /dev/null <<'EOF'
[{"insert": "c\n", "after": "a\n", "last": true}]
EOF
check "last on after inserts past the final anchor" 'a
b
a
c' "$(cat "$f")"

# A single match with last: true is still that match; the flag relaxes
# uniqueness, it does not demand plurality.
f=$(fixture last-one.txt 'only
')
out=$("$SCALPEL" edit "$f" <<'EOF'
[{"old": "only", "new": "one", "last": true}]
EOF
)
check "last with a single match still applies" 'one' "$(cat "$f")"
[[ "$out" != *"last of"* ]] \
  && ok "  ...without claiming to have chosen" \
  || no "  ...without claiming to have chosen" "$out"

f=$(fixture last-bad.txt 'x
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "y", "last": true, "replace_all": true}]
EOF
)
[[ $? -ne 0 && "$out" == *"contradict"* ]] \
  && ok "last with replace_all is refused" || no "last with replace_all is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"append": "y\n", "last": true}]
EOF
)
[[ $? -ne 0 && "$out" == *"means nothing"* ]] \
  && ok "last on an append is refused" || no "last on an append is refused" "$out"

out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "y", "last": "yes"}]
EOF
)
[[ $? -ne 0 && "$out" == *"true or false"* ]] \
  && ok "non-boolean last is refused" || no "non-boolean last is refused" "$out"

# The ambiguity message now offers last as a way out.
f=$(fixture hint.txt 'x
x
')
out=$("$SCALPEL" edit "$f" 2>&1 <<'EOF'
[{"old": "x", "new": "y"}]
EOF
)
[[ "$out" == *'"last": true'* ]] \
  && ok "ambiguity suggests last" || no "ambiguity suggests last" "$out"

print -r -- ""
print -r -- "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
