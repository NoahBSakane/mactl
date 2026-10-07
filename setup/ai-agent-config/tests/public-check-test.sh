#!/bin/bash
# public-check.py against throwaway repos and a throwaway HOME. Touches nothing real.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)/public-check.py"
export HOME="$(mktemp -d)"; trap 'rm -rf "$HOME"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); }; bad() { fail=$((fail+1)); echo "FAIL: $1"; }
repo="$HOME/r"; mkdir -p "$repo/ai-agent-config" && git -C "$repo" init -q . && cp "$SRC" "$repo/ai-agent-config/public-check.py"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid "$@"; }
pc() { python3 "$repo/ai-agent-config/public-check.py" "$@" 2>&1; }
commit() { g add -A && g commit -q -m "$1"; }
printf 'nothing special here\nsee https://github.com/NoahBSakane/mactl\n' >"$repo/a.md"; commit base
pc >/dev/null; [ $? = 0 ] && ok || bad "clean repo passes"
printf 'mail me at someone@corp.co.jp\n' >"$repo/b.md"; commit mail
out="$(pc)"; rc=$?; [ $rc = 1 ] && grep -q "b.md:1: \[email\]" <<<"$out" && ok || bad "an e-mail address is found"
printf 'bot@users.noreply.github.com Co-Authored-By x@example.org git@github.com\n' >"$repo/b.md"; commit ok-mail; pc >/dev/null; [ $? = 0 ] && ok || bad "noreply/example/github addresses are fine"
printf 'user <@U0ABCDEF123> and 11111111-2222-3333-4444-555555555555 at /Users/jdoe/work/x\n' >"$repo/c.md"; commit ids
out="$(pc)"; for r in slack-id uuid home-path; do grep -q "\[$r\]" <<<"$out" && ok || bad "$r is found"; done
printf 'path /Users/you/x and ~/x\n' >"$repo/c.md"; commit fine; pc >/dev/null; [ $? = 0 ] && ok || bad "placeholder paths are fine"
printf 'key AKIAABCDEFGHIJKLMNOP\n' >"$repo/d.md"; commit sec; out="$(pc)"; grep -q "\[secret\]" <<<"$out" && ok || bad "a secret is found"
printf 'secret\td.md\n' >"$repo/ai-agent-config/public-check.allow"; commit allow; pc >/dev/null; [ $? = 0 ] && ok || bad "public-check.allow silences a known-safe hit"
mkdir -p "$HOME/.config/ai-agent-config"; printf '# mine\nacme-?corp\n' >"$HOME/.config/ai-agent-config/public-denylist.txt"
printf 'We work for AcmeCorp.\n' >"$repo/e.md"; commit deny; out="$(pc)"; grep -q "e.md:1: \[denylist\]" <<<"$out" && ok || bad "a private denylist word is found (case-insensitive)"
# --diff looks only at added lines
printf 'harmless\n' >"$repo/e.md"; commit fixed; pc >/dev/null; [ $? = 0 ] && ok || bad "after the fix the repo is clean"
base="$(g rev-parse HEAD)"; printf 'Acme-Corp again\n' >>"$repo/e.md"; commit again
out="$(pc --diff "$base..HEAD")"; [ $? = 1 ] 2>/dev/null; grep -q "e.md" <<<"$out" && ok || bad "--diff finds a hit in added lines"
out="$(pc --diff "HEAD..HEAD")"; [ -z "$out" ] && ok || bad "--diff of an empty range is clean"
# pre-push protocol: a new branch (remote sha all zeros) is checked against origin/main-less history -> whole history
head="$(g rev-parse HEAD)"; printf 'refs/heads/x %s refs/heads/x %s\n' "$head" 0000000000000000000000000000000000000000 | python3 "$repo/ai-agent-config/public-check.py" --pre-push >/dev/null 2>&1; [ $? = 1 ] && ok || bad "--pre-push blocks a push that adds a hit"
printf 'refs/heads/x %s refs/heads/x %s\n' "$head" "$head" | python3 "$repo/ai-agent-config/public-check.py" --pre-push >/dev/null 2>&1; [ $? = 0 ] && ok || bad "--pre-push passes when nothing is new"
# --localise lists placeholders in ~/.knowledge
mkdir -p "$HOME/.knowledge"; printf 'id <自分のSlackユーザーID> and <TicketsデータベースのID>\n' >"$HOME/.knowledge/w.md"
out="$(python3 "$repo/ai-agent-config/public-check.py" --localise 2>&1)"; grep -q "自分のSlackユーザーID" <<<"$out" && grep -q "TicketsデータベースのID" <<<"$out" && ok || bad "--localise lists the placeholders"
rm -f "$HOME/.knowledge/w.md"; out="$(python3 "$repo/ai-agent-config/public-check.py" --localise 2>&1)"; grep -q "ありません" <<<"$out" && ok || bad "--localise with nothing to fill"
# --suggest hands the hits to an agent job (stubbed here) and prints what comes back; nothing is edited
stub="$HOME/stubhooks"; mkdir -p "$stub"; printf '#!/bin/bash\n[ "$1" = ask ] || exit 9\ncat >"%s/prompt.txt"\necho "STUB-SUGGESTION"\n' "$HOME" >"$stub/agent-run.sh"
printf 'We work for AcmeCorp.\n' >"$repo/f.md"; commit hit2
out="$(AGENTS_HOOKS_DIR="$stub" python3 "$repo/ai-agent-config/public-check.py" --suggest 2>&1)"
grep -q "STUB-SUGGESTION" <<<"$out" && grep -q "f.md:1" "$HOME/prompt.txt" && grep -q "編集せず" "$HOME/prompt.txt" && ok || bad "--suggest sends the hits to the ask job and prints the answer"
[ "$(cat "$repo/f.md")" = "We work for AcmeCorp." ] && ok || bad "--suggest never edits files"
echo "passed=$pass failed=$fail"; exit "$fail"
