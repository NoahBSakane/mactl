#!/bin/bash
# PreToolUse for EVERY agy tool, active only inside a research job (AGENT_JOB=1, set by agent-run.sh).
#
# The agy research template runs `agy -p ... --dangerously-skip-permissions`, so no per-domain
# allow-rule is needed and any page can be read. What keeps that read-only is this guard: inside a
# job it denies every tool except web search and page fetch (no shell, no file read or write, no
# browser, no MCP), and refuses fetches that could leak something (non-http(s), private/loopback
# hosts, credentials in the URL, secret-looking strings in the URL). Unlike the other hooks it
# FAILS CLOSED: a job that cannot be vetted is denied. Outside a job (an interactive agy) it does nothing.
[ -n "${AGENT_JOB:-}" ] || exit 0
deny() { printf '%s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || deny "【調査ジョブの制限】jq が無いため検証できません"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib.sh"
trap 'deny "【調査ジョブの制限】検証中にエラーが出たため拒否しました"' ERR
PAYLOAD="$(cat)"
jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || deny "【調査ジョブの制限】入力を読めないため拒否しました"
tool="$(jq -r '.tool_name // empty' <<<"$PAYLOAD")"
case "$tool" in
  search_web|task_boundary|notify_user|finish|wait|wait_5_seconds) exit 0 ;;
  read_url_content)
    url="$(jq -r '.tool_input.Url // .tool_input.url // empty' <<<"$PAYLOAD")"
    [[ "$url" =~ ^https?://([^/?#]+) ]] || deny "【調査ジョブの制限】http(s) 以外のURLは読めません"
    authority="${BASH_REMATCH[1]}"
    [[ "$authority" != *@* ]] || deny "【調査ジョブの制限】認証情報つきのURLは読めません"
    [[ "$authority" != \[* ]] || deny "【調査ジョブの制限】IPv6アドレスのURLは読めません"
    host="${authority%%:*}"; host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    if [[ "$host" == localhost || "$host" == *.local || "$host" == *.internal || "$host" == *.localdomain ]] \
       || [[ "$host" =~ ^(0|10|127)\. || "$host" =~ ^169\.254\. || "$host" =~ ^192\.168\. || "$host" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] \
       || [[ "$host" =~ ^[0-9]+$ || "$host" =~ ^0x ]]; then
      deny "【調査ジョブの制限】内部アドレス($host)は読めません"
    fi
    hit="$(secret_hit "$url")"
    [ -z "$hit" ] || deny "【調査ジョブの制限】URLに秘密情報らしき文字列(${hit:0:6}…)が含まれています"
    exit 0 ;;
  *) deny "【調査ジョブの制限】調査ジョブでは $tool を使えません(使えるのはWeb検索とページ取得だけ)" ;;
esac
