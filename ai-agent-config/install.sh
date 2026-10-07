#!/bin/bash
# Deploys everything listed in manifest.tsv onto this Mac (instruction files, skills, hooks,
# settings merges). Portable: all paths resolve through $HOME. Safe to re-run.
#
# 何も付けずに実行すると、まず計画(dry-run)を表示し、「実行しますか? [y/N]」と確認します。
#
# オプションの規則: 小文字 = 簡潔(出力は少なめ・対象は狭い)、大文字 = 詳細・徹底(出力は多め・対象は広い)。
#
#   -n  --dry-run          計画だけ表示して終了
#   -N  --dry-run-diff     計画に加えて、変更される内容の差分も表示して終了
#   -y  --yes              確認なしで実行(計画は出さず、結果の要約だけ表示。スクリプト・cron向け)
#   -Y  --yes-verbose      確認なしで実行(計画と、配備した行も表示)
#   -f  --force            live側が編集されている(DRIFT)ファイルも、退避してから上書き
#   -F  --force-all        -f に加えて、種(seed)の行(台帳)も、リポジトリの種の内容へ戻す
#   -r  --rollback [TS]    配備を元に戻す(確認あり。TSを省くと最新)。-y で確認なし、-n で計画だけ
#   -R  --rollback-diff [TS]  -r に加えて、戻すと変わる内容の差分も表示
#   -o  --only ID          manifestの1行(1つの配備物)だけを対象にする
#   -l  --list-backups     退避(配備の履歴)の一覧
#   -h  --help             この説明
# 短いオプションは束ねられます(例: -fy)。非対話(端末でない)実行で -y/-Y が無い場合は、
# 計画を表示するだけで実行しません。
#
# 終了コード: 0 正常(中止・dry-run・変更なしを含む) / 2 引数の誤り / 3 DRIFTのため中止 / 4 計算できない行がある
#
# 上書きする前の内容は ~/.agent-state/backups/<TS>/ に退避します。JSON設定は、管理対象の
# エントリだけをマージし、rollbackでも、そのエントリだけを外します。
set -uo pipefail
CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$CFG_DIR/doctor.sh" --required || exit 1   # 必須のツールが無ければ、何が足りないかを示して止める
. "$CFG_DIR/manifest-lib.sh"

YES=0; QUIET=0; DRY=0; SHOWDIFF=0; FORCE=0; FORCE_SEED=0; ONLY=""; ROLLBACK=""; ROLLBACK_REQ=0; LIST=0

# split clustered short options: -fy -> -f -y
argv=()
for a in "$@"; do
  if [[ "$a" =~ ^-[A-Za-z]{2,}$ ]]; then
    for ((i = 1; i < ${#a}; i++)); do argv+=("-${a:i:1}"); done
  else argv+=("$a"); fi
done
set -- ${argv[@]+"${argv[@]}"}
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=1; QUIET=1 ;;
    -Y|--yes-verbose) YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    -N|--dry-run-diff) DRY=1; SHOWDIFF=1 ;;
    -f|--force) FORCE=1 ;;
    -F|--force-all) FORCE=1; FORCE_SEED=1 ;;
    -o|--only) ONLY="${2:-}"; shift ;;
    -r|--rollback) ROLLBACK_REQ=1; if [ $# -gt 1 ] && [[ "$2" != -* ]]; then ROLLBACK="$2"; shift; fi ;;
    -R|--rollback-diff) ROLLBACK_REQ=1; SHOWDIFF=1; if [ $# -gt 1 ] && [[ "$2" != -* ]]; then ROLLBACK="$2"; shift; fi ;;
    -l|--list-backups) LIST=1 ;;
    -h|--help) sed -n 2,24p "$0"; exit 0 ;;
    *) echo "不明なオプション: $1(-h で一覧)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$DRY" -eq 1 ] && [ "$YES" -eq 1 ]; then echo "-n/-N と -y/-Y は同時に指定できません" >&2; exit 2; fi
BACKUPS="$STATE_DIR/backups"
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# confirm <question>: 0=yes 1=no 2=cannot ask (not a terminal)
confirm() {
  if [ -t 0 ] || [ -n "${AI_CONFIG_ASSUME_TTY:-}" ]; then
    printf '%s [y/N] ' "$1" >&2
    local ans=""; read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
  echo "非対話の実行のため確認できません。実行するには -y を付けてください。" >&2
  return 2
}

# the instruction files agents must not edit directly (manifest rows flagged `protect`); the gate reads this
write_protected() {
  mkdir -p "$STATE_DIR"; local tmp="$STATE_DIR/protected-paths.txt.tmp"; : >"$tmp"
  protect_cb() { [ "${6:-}" = protect ] && cond_ok "$5" && printf '%s\n' "$4" >>"$tmp"; return 0; }
  each_row protect_cb; mv "$tmp" "$STATE_DIR/protected-paths.txt"
}

if [ "$LIST" -eq 1 ]; then ls -1 "$BACKUPS" 2>/dev/null || echo "(バックアップなし)"; exit 0; fi

# ---------------------------------------------------------------- rollback
if [ "$ROLLBACK_REQ" -eq 1 ] && [ -z "$ROLLBACK" ]; then ROLLBACK="$(ls -1 "$BACKUPS" 2>/dev/null | tail -1)"; fi
if [ "$ROLLBACK_REQ" -eq 1 ]; then
  [ -n "$ROLLBACK" ] || { echo "退避(配備の履歴)がありません" >&2; exit 1; }
  BK="$BACKUPS/$ROLLBACK"; LOG="$BK/applied.tsv"
  [ -f "$LOG" ] || { echo "バックアップが見つかりません: $BK(-l で一覧)" >&2; exit 1; }
  show_rb_diff() { # id mode dest prior: what rolling back would change in this file
    [ "$4" = exists ] || return 0
    case "$2" in
      link) echo "      リンク: 現在 $(readlink "$3" 2>/dev/null || echo '(なし)') → 元 $(readlink "$BK/files/$1" 2>/dev/null)" ;;
      copydir) diff -ru "$3" "$BK/files/$1" 2>/dev/null | head -30 | sed 's/^/      /' ;;
      merge-codex-persona|copy|seed) diff -u "$3" "$BK/files/$1" 2>/dev/null | head -30 | sed 's/^/      /' ;;
      merge-*) diff -u <(jq -S . "$3" 2>/dev/null) <(jq -S . "$BK/files/$1" 2>/dev/null) 2>/dev/null | head -30 | sed 's/^/      /' ;;
    esac
    return 0
  }
  echo "ロールバック計画(配備 $ROLLBACK を元に戻す):"
  tail -r "$LOG" | while IFS=$'\t' read -r id mode dest prior post; do
    case "$mode" in
      merge-*) act="管理対象の設定だけを外す(配備後に他が変わっていなければ、退避から復元)" ;;
      *) if [ "$prior" = exists ]; then act="退避から復元"; else act="削除(配備前は存在しなかった)"; fi ;;
    esac
    printf '  %-34s %s  → %s\n' "$id" "$dest" "$act"
    [ "$SHOWDIFF" -eq 0 ] || show_rb_diff "$id" "$mode" "$dest" "$prior"
  done
  [ "$DRY" -eq 1 ] && { echo "(dry-run: 変更なし)"; exit 0; }
  if [ "$YES" -eq 0 ]; then confirm "上記のとおり元に戻しますか?"; rc=$?; [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && echo "中止しました"; exit 0; }; fi
  # newest row first, so dependent rows (links) unwind before what they point at
  tail -r "$LOG" | while IFS=$'\t' read -r id mode dest prior post; do
    case "$mode" in
      merge-*)
        if [ -f "$dest" ] && [ "$(live_hash "$mode" "$dest")" = "$post" ] && [ "$prior" = exists ]; then
          cat "$BK/files/$id" >"$dest"; echo "[restored] $id"
        elif [ -f "$dest" ]; then
          unmerge_json "$mode" "$dest" "$id" >"$WORK/unmerged.json" && cat "$WORK/unmerged.json" >"$dest"
          echo "[unmerged] $id: 管理対象のエントリだけ外しました(元の内容は $BK/files/$id を参照)"
        fi ;;
      *)
        rm -rf "$dest"
        if [ "$prior" = exists ]; then mkdir -p "$(dirname "$dest")"; cp -a "$BK/files/$id" "$dest"; echo "[restored] $id"; else echo "[removed] $id"; fi ;;
    esac
    [ -f "$RECORD" ] && { grep -v "^$id	" "$RECORD" >"$RECORD.tmp" 2>/dev/null; mv "$RECORD.tmp" "$RECORD"; }
  done
  exit 0
fi

# ---------------------------------------------------------------- plan
ids=(); modes=(); srcs=(); dests=(); conds=(); sts=(); n=0; drift=0; errors=0; changes=0
show_diff() { # id mode src dest
  local id="$1" mode="$2" src="$3" dest="$4"
  case "$mode" in
    link) echo "      リンク: $(readlink "$dest" 2>/dev/null || echo '(なし)') → $(expand "$src")" ;;
    copydir) diff -ru "$dest" "$WORK/$id" 2>/dev/null | head -40 | sed 's/^/      /' ;;
    merge-codex-persona|copy|seed) diff -u "$dest" "$WORK/$id" 2>/dev/null | head -40 | sed 's/^/      /' || true ;;
    merge-*) diff -u <(jq -S . "$dest" 2>/dev/null) <(jq -S . "$WORK/$id") 2>/dev/null | head -40 | sed 's/^/      /' ;;
    *) diff -u "$dest" "$WORK/$id" 2>/dev/null | head -40 | sed 's/^/      /' ;;
  esac
}
collect() {
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || return 0
  row_status "$1" "$2" "$3" "$4" "$5"
  if [ "$FORCE_SEED" -eq 1 ] && [ "$2" = seed ] && [ "$ST" = OK ] && [ "$(live_hash seed "$4")" != "$WANT" ]; then ST=UPDATE; fi
  ids[$n]="$1"; modes[$n]="$2"; srcs[$n]="$3"; dests[$n]="$4"; conds[$n]="$5"; sts[$n]="$ST"
  case "$ST" in
    DRIFT) drift=$((drift+1)); [ "$FORCE" -eq 1 ] && changes=$((changes+1)) ;;
    ERROR) errors=$((errors+1)) ;;
    MISSING|UPDATE) changes=$((changes+1)) ;;
  esac
  n=$((n+1))
  [ "$QUIET" -eq 1 ] || printf '  [%-7s] %-32s %s\n' "$ST" "$1" "$4"
  if [ "$SHOWDIFF" -eq 1 ] && { [ "$ST" = UPDATE ] || [ "$ST" = DRIFT ]; }; then show_diff "$1" "$2" "$3" "$4"; fi
  return 0
}
say "計画(manifest: $MANIFEST)"
each_row collect

if [ "$errors" -gt 0 ]; then
  echo >&2; echo "中止: ${errors}件の行で、配備後の内容を計算できませんでした(何も変更していません):" >&2
  i=0; while [ "$i" -lt "$n" ]; do
    [ "${sts[$i]}" = ERROR ] && { echo "  ${ids[$i]}: $(cat "$WORK/${ids[$i]}.err" 2>/dev/null | head -1)" >&2; }; i=$((i+1)); done
  exit 4
fi
if [ "$drift" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  cat >&2 <<EOF

中止: ${drift}件のlive側ファイルが、前回の配備以降に(または未導入の状態で)repoと異なる内容になっています。
上書きすると未取込みの変更が失われます。次のいずれかを行ってください:
  - diff-ai-agent-config.sh で差分を確認し、reconcile-agent-config skill で取り込む
  - 内容を確認済みなら -f(上書き前に ~/.agent-state/backups/ へ退避します)
EOF
  exit 3
fi
if [ "$DRY" -eq 1 ]; then echo "(dry-run: 変更なし。変更される行: ${changes}件)"; exit 0; fi
if [ "$changes" -eq 0 ]; then write_protected; echo "変更なし(すべて最新)"; exit 0; fi
if [ "$YES" -eq 0 ]; then
  confirm "上記のうち ${changes} 件を配備しますか?"; rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && echo "中止しました(変更なし)"; exit 0; }
fi

# ---------------------------------------------------------------- apply
TS="$(date +%Y%m%d%H%M%S)"; BK="$BACKUPS/$TS"; mkdir -p "$BK/files"; : >"$BK/applied.tsv"
changed=0
i=0
while [ "$i" -lt "$n" ]; do
  id="${ids[$i]}"; mode="${modes[$i]}"; src="${srcs[$i]}"; dest="${dests[$i]}"; st="${sts[$i]}"
  i=$((i+1))
  case "$st" in MISSING|UPDATE) ;; DRIFT) [ "$FORCE" -eq 1 ] || continue ;; *) continue ;; esac
  prior=absent
  if [ -e "$dest" ] || [ -L "$dest" ]; then prior=exists; cp -a "$dest" "$BK/files/$id"; fi
  # several rows can merge into the same file (e.g. Muse hooks + context): rebuild from what is
  # on disk *now*, not from the plan-time content, or each row would undo the previous one
  [[ "$mode" != merge-* ]] || build_desired "$id" "$mode" "$src" "$dest" >/dev/null
  mkdir -p "$(dirname "$dest")"
  case "$mode" in
    copy|seed) [ ! -L "$dest" ] || rm -f "$dest"; cp -p "$WORK/$id" "$dest" ;;
    copydir) mkdir -p "$dest"; rsync -a --delete "$WORK/$id/" "$dest/" ;;
    link) rm -rf "$dest"; ln -s "$(expand "$src")" "$dest" ;;
    merge-*) [ -f "$dest" ] || : >"$dest"; cat "$WORK/$id" >"$dest" ;;
    shims) mkdir -p "$dest"; cp -p "$WORK/$id"/* "$dest/" ;;
  esac
  post="$(live_hash "$mode" "$dest")"
  [[ "$mode" == merge-* ]] || record_hash "$id" "$post"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$mode" "$dest" "$prior" "$post" >>"$BK/applied.tsv"
  say "  deployed: $id"
  changed=$((changed+1))
done

write_protected
if [ "$changed" -eq 0 ]; then rm -rf "$BK"; echo "変更なし(すべて最新)"; else
  echo "完了: ${changed}件を配備しました。退避先: $BK(戻す: install.sh -r)"
  say "注意: 動作中のセッションが読み込むhook設定の反映時期はツール次第です。新しいセッションから確実に有効になります。"
fi
exit 0
