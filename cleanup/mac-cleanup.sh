#!/bin/bash
# Inspect reclaimable Mac storage, then clean explicitly selected cache categories.
# With no arguments this script only reads paths and reports allocated disk usage;
# --apply is the sole gate for every destructive operation. Native cleanup commands
# are preferred so each package manager can preserve its own storage invariants.
# mise's documented --dry-run is used to preview unused runtimes without pruning.
#
# All manually managed paths are rooted in HOME. Reject ambiguous/outside paths,
# skip symlinks (including parent components), and never manually delete personal
# documents, Trash, Xcode Archives, or Cargo's index/bin. Application Support
# is limited to the explicit app-caches allowlist below.
# Manual removal is centralized below and includes hidden children without globs.
# Native Homebrew cleanup also manages its own installation prefix; its additional
# savings, mise runtime pruning and unavailable simulators are not in the estimate.
#
# Category failures are reported and isolated; a safety violation exits immediately.
# Estimates are upper bounds, not promises: shared blocks, tool retention policies,
# files in use and APFS snapshots can change the actual free-space gain. Re-running
# is safe; missing tools/paths are harmless. Requires macOS and Bash 3.2 or newer.

set -euo pipefail

APPLY=0
ONLY=''
SKIP=''
TOTAL_KIB=0
WARNINGS=0
OLDER_THAN_DAYS=30
CATEGORIES='brew npm pnpm uv pip cargo deno mise xcode browsers-test app-caches user-caches dot-cache huggingface repo-artifacts logs'

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
warn() { printf 'warning: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
has() { command -v "$1" >/dev/null 2>&1; }
contains() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

# A CLI's --dry-run can still try to update metadata or caches. Deny filesystem
# writes for the external probes as well; never fall back to an unconfined probe.
read_only() {
    has sandbox-exec || return 1
    sandbox-exec -p '(version 1) (allow default) (deny file-write*)' "$@"
}

describe() {
    case "$1" in
        brew) echo 'Homebrew のダウンロードキャッシュ・旧版' ;;
        npm) echo 'npm のパッケージキャッシュ' ;;
        pnpm) echo 'pnpm store の未参照パッケージ' ;;
        uv) echo 'uv のキャッシュ' ;;
        pip) echo 'Python pip のキャッシュ' ;;
        cargo) echo 'Cargo registry の cache/src のみ' ;;
        deno) echo 'Deno のキャッシュ' ;;
        mise) echo 'mise の未使用ランタイム・キャッシュ' ;;
        xcode) echo 'Xcode DerivedData の中身・利用不能なシミュレータ' ;;
        browsers-test) echo 'Playwright / Puppeteer のテスト用ブラウザ' ;;
        app-caches) echo 'LINE・UTM・壁紙・Claude・Codex の許可リスト（中身のみ）' ;;
        user-caches) echo 'Library/Caches の一般キャッシュ（除外あり）' ;;
        dot-cache) echo '.cache の一般キャッシュ（除外あり）' ;;
        huggingface) echo 'Hugging Face モデルキャッシュ（既定無効、--only で明示）' ;;
        repo-artifacts) echo '未使用プロジェクトの再生成可能な成果物（既定無効、--only で明示）' ;;
        logs) echo 'Library/Logs の更新から14日超の通常ファイル' ;;
    esac
}

usage() {
    cat <<'EOF'
使い方: mac-cleanup.sh [--apply] [--only cat1,cat2] [--skip cat1,cat2]
                      [--older-than-days N]
        mac-cleanup.sh --list | -h | --help

引数なしは dry-run。対象パス・現在サイズ・見込み削減量の上限を表示します。
--apply       実際に清掃し、Data ボリュームの df を前後比較
--only LIST   指定カテゴリだけ選択（huggingface / repo-artifacts はこの指定が必須）
--skip LIST   指定カテゴリを除外（--only より優先）
--older-than-days N  repo-artifacts の未更新日数（0以上の整数、既定30）
--list        カテゴリ一覧
-h, --help    この説明
同じ選択オプションを複数回指定した場合はリストを追加します。
repo-artifacts の探索先は $HOME/Repos。MAC_CLEANUP_REPO_ROOTS で上書き可
（コロン区切り、各要素は $HOME 配下の安全な絶対パス）。
root 実行不可。アプリ起動中なら終了してから --apply 推奨。
EOF
}

[[ $EUID -ne 0 ]] || die 'root では実行できません。sudo を使わないでください。'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --older-than-days)
            [[ $# -ge 2 ]] || die "$1 に日数が必要です"
            case "$2" in ''|*[!0-9]*) die '--older-than-days は0以上の整数が必要です' ;; esac
            OLDER_THAN_DAYS=$2
            shift 2 ;;
        --only|--skip)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 にカテゴリが必要です"
            case "$2" in ,*|*,|*,,*|*[[:space:]]*) die "不正なリスト: $2" ;; esac
            if [[ "$1" == --only ]]; then ONLY="${ONLY:+$ONLY,}$2"
            else SKIP="${SKIP:+$SKIP,}$2"; fi
            shift 2 ;;
        --list)
            for category in $CATEGORIES; do printf '%-15s %s\n' "$category" "$(describe "$category")"; done
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "不明な引数: $1" ;;
    esac
done
IFS=',' read -r -a requested <<< "${ONLY}${ONLY:+,}${SKIP}"
for category in "${requested[@]:-}"; do
    [[ -z "$category" ]] && continue
    case " $CATEGORIES " in *" $category "*) ;; *) die "不明なカテゴリ: $category" ;; esac
done

# Do not normalize '..' away: reject it before checking physical path components.
case "${HOME:-}" in ''|/|/*/|*//*|*/../*|*/..|*/./*|*/.) die '安全でない HOME です' ;; esac
[[ "$HOME" == /* && -d "$HOME" ]] || die 'HOME は既存の絶対ディレクトリである必要があります'

safe_path() {
    local path="$1" current='' part rest
    [[ -n "$path" && "$path" == "$HOME/"* && "$path" != "$HOME/" ]] || die "安全検証失敗: $path"
    case "$path" in *//*|*/../*|*/..|*/./*|*/.|*/) die "曖昧なパス: $path" ;; esac
    rest=${path#/}
    while [[ -n "$rest" ]]; do
        part=${rest%%/*}
        current="$current/$part"
        if [[ -L "$current" ]]; then
            printf '  skip: シンボリックリンク %s\n' "$current"
            return 1
        fi
        if [[ "$rest" == */* ]]; then rest=${rest#*/}; else rest=''; fi
    done
    return 0
}

human_size() {
    awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k/1048576;
        else if (k >= 1024) printf "%.1f MiB", k/1024; else printf "%d KiB", k }'
}

measure() {
    local path="$1" kind="${2:-estimate}" result kib
    safe_path "$path" || return 0
    if [[ ! -e "$path" ]]; then printf '  0 KiB  %s（未作成）\n' "$path"; return 0; fi
    if ! result=$(du -skP "$path" 2>/dev/null); then
        warn "サイズ取得不可（合計未算入）: $path"
        return 0
    fi
    kib=${result%%[[:space:]]*}
    case "$kib" in ''|*[!0-9]*) warn "サイズ解析不可: $path"; return 0 ;; esac
    printf '  %s  %s' "$(human_size "$kib")" "$path"
    if [[ "$kind" == reference ]]; then printf '（参考・合計未算入）'; else TOTAL_KIB=$((TOTAL_KIB + kib)); fi
    printf '\n'
}

# The only deletion gateway. All native mutating commands also enter here.
# Explicit returns are required: category calls are in an if condition, where
# Bash disables errexit inside functions. A safety error uses exit, never return.
cleanup() {
    local mode="$1" path="$2" child
    shift 2
    [[ $APPLY -eq 1 ]] || return 0
    safe_path "$path" || return 0
    if [[ "$mode" == native ]]; then "$@" || return 1; return 0; fi
    [[ -e "$path" ]] || return 0
    case "$mode" in
        contents)
            [[ -d "$path" ]] || return 1
            # An empty NUL record signals find failure to the parent shell.
            # Real paths are never empty; newline-containing names remain intact.
            while IFS= read -r -d '' child; do
                [[ -n "$child" ]] || return 1
                cleanup tree "$child" || return 1
            done < <(find -P "$path" -mindepth 1 -maxdepth 1 -print0 || printf '\0')
            ;;
        tree) rm -rf -- "$path" || return 1 ;;
        file) find -P "$path" -maxdepth 0 -type f -mtime +14 -exec rm -f -- {} + || return 1 ;;
        *) die "不明な削除モード: $mode" ;;
    esac
    return 0
}

# Use the same ChatGPT process test as the maintenance Makefile.
codex_running() {
    /bin/ps -axo ucomm= | /usr/bin/awk '$1 == "ChatGPT" { found=1 } END { exit !found }'
}

app_caches() {
    local path failed=0 deferred=0
    local -a cache_dirs=(
        "$HOME/Library/Containers/jp.naver.line.mac/Data/Library/Caches"
        "$HOME/Library/Group Containers/VUTU7AKEUR.jp.naver.line.mac/Real/Library/Data/Caches"
        "$HOME/Library/Group Containers/VUTU7AKEUR.jp.naver.line.mac/Library/Caches"
        "$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Caches"
        "$HOME/Library/Application Support/com.apple.wallpaper/aerials"
        "$HOME/Library/Application Support/Claude/Cache"
        "$HOME/Library/Application Support/Claude/Code Cache"
        "$HOME/Library/Application Support/Claude/GPUCache"
        "$HOME/Library/Application Support/Claude/DawnGraphiteCache"
        "$HOME/Library/Application Support/Claude/DawnWebGPUCache"
        "$HOME/Library/Application Support/Claude/Partitions/launch-preview-static/Cache"
        "$HOME/Library/Application Support/Claude/Partitions/launch-preview-static/Code Cache"
        "$HOME/Library/Application Support/Claude/Partitions/cowork-file-preview/Cache"
        "$HOME/Library/Application Support/Claude/Partitions/cowork-file-preview/Code Cache"
        "$HOME/Library/Caches/com.anthropic.claudefordesktop"
    )
    local -a codex_cache_dirs=(
        "$HOME/Library/Application Support/Codex/Cache"
        "$HOME/Library/Application Support/Codex/Code Cache"
        "$HOME/Library/Application Support/Codex/GPUCache"
        "$HOME/Library/Application Support/Codex/DawnGraphiteCache"
        "$HOME/Library/Application Support/Codex/DawnWebGPUCache"
        "$HOME/Library/Application Support/Codex/GraphiteDawnCache"
        "$HOME/Library/Application Support/Codex/component_crx_cache"
        "$HOME/Library/Application Support/Codex/Default/GPUCache"
        "$HOME/Library/Application Support/Codex/Default/DawnGraphiteCache"
        "$HOME/Library/Application Support/Codex/Default/DawnWebGPUCache"
        "$HOME/Library/Application Support/Codex/Default/Partitions/codex-browser-app/GPUCache"
        "$HOME/Library/Application Support/Codex/Default/Partitions/codex-browser-app/DawnGraphiteCache"
        "$HOME/Library/Application Support/Codex/Default/Partitions/codex-browser-app/DawnWebGPUCache"
        "$HOME/Library/Application Support/Codex/GPUPersistentCache/GPUCache"
        "$HOME/Library/Caches/Codex"
        "$HOME/Library/Caches/com.openai.codex"
        "$HOME/.codex/cache"
    )
    if codex_running; then
        deferred=1
        printf '  Codex is running; its caches are deferred until it is closed.\n'
    fi
    for path in "${cache_dirs[@]}" "${codex_cache_dirs[@]}"; do
        if [[ $deferred -eq 1 ]]; then
            case "$path" in
                "$HOME/Library/Application Support/Codex/"*|"$HOME/Library/Caches/Codex"|"$HOME/Library/Caches/com.openai.codex"|"$HOME/.codex/cache")
                    printf '  deferred: %s\n' "$path"
                    continue ;;
            esac
        fi
        safe_path "$path" || continue
        if [[ -e "$path" && ! -d "$path" ]]; then
            printf '  skip: ディレクトリではありません %s\n' "$path"
            continue
        fi
        measure "$path"
        cleanup contents "$path" || { warn "削除失敗: $path"; failed=1; }
    done
    return "$failed"
}

generic_entries() {
    local root="$1" kind="$2" path name failed=0
    safe_path "$root" || return 0
    [[ -d "$root" ]] || { measure "$root"; return 0; }
    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || return 1
        name=${path##*/}
        if [[ "$kind" == user ]]; then
            # app-caches owns the last three: honor --skip and Codex deferral.
            case "$name" in com.apple.*|Homebrew|pip|deno|ms-playwright|pnpm|mise|com.anthropic.claudefordesktop|Codex|com.openai.codex) continue ;; esac
        else
            case "$name" in codex-runtimes|huggingface|uv|puppeteer|mise) continue ;; esac
        fi
        safe_path "$path" || continue
        # TCC-protected system caches (CloudKit, FamilyCircle, ...) can't even be
        # listed; skip them instead of letting one EPERM abort the whole category.
        if [[ -d "$path" ]] && ! ls -A "$path" >/dev/null 2>&1; then
            printf '  skip: 読み取り不可（macOS 保護） %s\n' "$path"
            continue
        fi
        measure "$path"
        if [[ "$kind" == user && -d "$path" ]]; then cleanup contents "$path" || { warn "削除失敗: $path"; failed=1; }
        else cleanup tree "$path" || { warn "削除失敗: $path"; failed=1; }; fi
    done < <(find -P "$root" -mindepth 1 -maxdepth 1 -print0 || printf '\0')
    return "$failed"
}

# Share the same manifest-qualified pruning rules for discovery and age checks.
# stat runs in batches; no temporary files or traversal into artifacts/.git.
repo_find() {
    local root="$1" mode="$2"
    local -a predicate=(
        '(' -name .git -prune ')' -o
        '(' -type d '('
            '(' '(' -name node_modules -o -name .next -o -name .nuxt -o
                -name .turbo -o -name .parcel-cache -o -name .svelte-kit ')'
                -exec /bin/test -f '{}/../package.json' ';' ')' -o
            '(' -name target -exec /bin/test -f '{}/../Cargo.toml' ';' ')' -o
            '(' -name .venv '('
                -exec /bin/test -f '{}/../pyproject.toml' ';' -o
                -exec /bin/test -f '{}/../requirements.txt' ';' -o
                -exec /bin/test -f '{}/../setup.py' ';' -o
                -exec /bin/test -f '{}/../uv.lock' ';' ')' ')'
        ')' -prune
    )
    case "$mode" in
        candidates) find -P "$root" -mindepth 1 "${predicate[@]}" -print0 ')' ;;
        mtimes) find -P "$root" -mindepth 1 "${predicate[@]}" ')' -o \
            -type f -exec /usr/bin/stat -f '%m' '{}' + ;;
        *) return 1 ;;
    esac
}

repo_artifacts() {
    local rest="${MAC_CLEANUP_REPO_ROOTS-$HOME/Repos}" root path project existing
    local duplicate tracked latest now before failed=0
    local -a roots=() artifacts=() projects=()
    # Validate every element before processing anything (including empty elements).
    while :; do
        root=${rest%%:*}
        if safe_path "$root"; then roots+=("$root"); fi
        [[ "$rest" == *:* ]] || break
        rest=${rest#*:}
    done
    has git || { warn 'Git がないため repo-artifacts をスキップします'; return 1; }
    now=$(date +%s) || return 1
    for root in "${roots[@]:-}"; do
        [[ -n "$root" && -d "$root" ]] || continue
        printf '  探索: %s\n' "$root"
        while IFS= read -r -d '' path; do
            [[ -n "$path" ]] || { warn "探索失敗: $root"; failed=1; break; }
            safe_path "$path" || continue
            duplicate=0
            for existing in "${artifacts[@]:-}"; do
                [[ "$existing" != "$path" ]] || { duplicate=1; break; }
            done
            [[ $duplicate -eq 0 ]] || continue
            artifacts+=("$path")
            project=${path%/*}
            duplicate=0
            for existing in "${projects[@]:-}"; do
                [[ "$existing" != "$project" ]] || { duplicate=1; break; }
            done
            [[ $duplicate -ne 0 ]] || projects+=("$project")
        done < <(repo_find "$root" candidates || printf '\0')
    done
    # Incomplete discovery must not result in partial deletion.
    [[ $failed -eq 0 ]] || return 1
    for project in "${projects[@]:-}"; do
        [[ -n "$project" ]] || continue
        safe_path "$project" || continue
        printf '\n  プロジェクト: %s\n' "$project"
        if ! tracked=$(git -C "$project" rev-parse --is-inside-work-tree 2>/dev/null) || [[ "$tracked" != true ]]; then
            printf '  skip: Git 作業ツリーを確認できません %s\n' "$project"
            continue
        fi
        if ! latest=$(repo_find "$project" mtimes | awk '
            !/^-?[0-9]+$/ { bad=1; next }
            !seen || $1 > newest { newest=$1 }
            { seen=1 }
            END { if (bad) exit 1; if (seen) printf "%.0f\n", newest }'); then
            warn "更新日時の取得失敗（スキップ）: $project"
            failed=1
            continue
        fi
        # Decimal arithmetic in awk avoids Bash octal parsing and integer overflow.
        if [[ -n "$latest" ]] && awk -v latest="$latest" -v now="$now" -v days="$OLDER_THAN_DAYS" \
            'BEGIN { exit !(latest >= now - days * 86400) }'; then
            printf '  skip: 最近更新(%s日以内) %s\n' "$OLDER_THAN_DAYS" "$project"
            continue
        fi
        before=$TOTAL_KIB
        for path in "${artifacts[@]:-}"; do
            [[ "${path%/*}" == "$project" ]] || continue
            if ! tracked=$(git -C "$project" ls-files -- "${path##*/}"); then
                warn "Git 追跡確認失敗（スキップ）: $path"
                failed=1
                continue
            fi
            if [[ -n "$tracked" ]]; then
                printf '  skip: Git 追跡ファイルあり %s\n' "$path"
                continue
            fi
            measure "$path"
            cleanup tree "$path" || { warn "削除失敗: $path"; failed=1; }
        done
        printf '  プロジェクト見込み合計: %s\n' "$(human_size "$((TOTAL_KIB - before))")"
    done
    return "$failed"
}

preview_mise() {
    local output status=0
    output=$(read_only env MISE_DATA_DIR="$HOME/.local/share/mise" MISE_CACHE_DIR="$HOME/Library/Caches/mise" \
        MISE_INSTALLS_DIR="$HOME/.local/share/mise/installs" MISE_LOG_LEVEL=info NO_COLOR=1 mise prune --dry-run 2>&1) || status=1
    printf '%s\n' "$output"
    # Some mise versions return success even when tracked configs cannot resolve.
    case "$output" in *WARN*|*ERROR*) status=1 ;; esac
    if [[ $status -ne 0 ]]; then
        warn 'mise の読み取り専用プレビューが失敗または警告を返しました。ランタイムの削除をスキップします。'
    fi
    return "$status"
}

run_category() {
    local category="$1" path child failed=0
    case "$category" in
        brew|npm|pnpm|uv|cargo|deno|mise) has "$category" || return 0 ;;
        pip) has python3 || return 0
            read_only env PYTHONDONTWRITEBYTECODE=1 python3 -B -m pip --version >/dev/null 2>&1 || return 0 ;;
    esac
    printf '\n[%s] %s\n' "$category" "$(describe "$category")"
    case "$category" in
        brew)
            path="$HOME/Library/Caches/Homebrew"; measure "$path"
            printf '  Homebrew 管理の旧版削除量は合計未算入\n'
            cleanup native "$path" env HOMEBREW_CACHE="$path" HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup -s --prune=all ;;
        npm)
            path="$HOME/.npm"; measure "$path/_cacache"
            cleanup native "$path/_cacache" npm --cache "$path" cache clean --force ;;
        pnpm)
            path="$HOME/Library/pnpm/store"; measure "$path"
            printf '  store 全体のサイズです。実際には未参照分のみ削除\n'
            cleanup native "$path" pnpm --store-dir "$path" store prune ;;
        uv)
            path="$HOME/.cache/uv"; measure "$path"
            cleanup native "$path" uv --cache-dir "$path" cache clean ;;
        pip)
            path="$HOME/Library/Caches/pip"; measure "$path"
            cleanup native "$path" python3 -B -m pip --cache-dir "$path" cache purge ;;
        cargo)
            for child in cache src; do
                path="$HOME/.cargo/registry/$child"; measure "$path"
                cleanup tree "$path" || failed=1
            done
            return "$failed" ;;
        deno)
            path="$HOME/Library/Caches/deno"; measure "$path"
            if [[ $APPLY -eq 1 ]]; then
                if deno clean --help >/dev/null 2>&1; then
                    cleanup native "$path" env DENO_DIR="$path" deno clean
                else cleanup tree "$path"; fi
            fi ;;
        mise)
            path="$HOME/Library/Caches/mise"; measure "$path"
            measure "$HOME/.local/share/mise/installs" reference
            if safe_path "$HOME/.local/share/mise/installs" && safe_path "$path"; then
                preview_mise || failed=1
                if [[ $APPLY -eq 1 ]]; then
                    if [[ $failed -eq 0 ]]; then
                        cleanup native "$HOME/.local/share/mise/installs" env MISE_DATA_DIR="$HOME/.local/share/mise" MISE_INSTALLS_DIR="$HOME/.local/share/mise/installs" MISE_CACHE_DIR="$path" mise prune --yes || failed=1
                    fi
                    cleanup native "$path" env MISE_DATA_DIR="$HOME/.local/share/mise" MISE_CACHE_DIR="$path" mise cache clear || failed=1
                fi
            fi
            return "$failed" ;;
        xcode)
            path="$HOME/Library/Developer/Xcode/DerivedData"; measure "$path"
            cleanup contents "$path" || failed=1
            measure "$HOME/Library/Developer/CoreSimulator/Devices" reference
            printf '  シミュレータは利用不能分だけを削除（合計未算入）\n'
            if [[ $APPLY -eq 1 ]] && has xcrun && xcrun --find simctl >/dev/null 2>&1; then
                path="$HOME/Library/Developer/CoreSimulator/Devices"
                cleanup native "$path" xcrun simctl --set "$path" delete unavailable || failed=1
            fi
            return "$failed" ;;
        browsers-test)
            for path in "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/puppeteer"; do
                measure "$path"; cleanup tree "$path" || failed=1
            done
            return "$failed" ;;
        app-caches) app_caches ;;
        user-caches)
            printf '  注意: アプリ起動中なら終了してから --apply 推奨\n'
            generic_entries "$HOME/Library/Caches" user ;;
        dot-cache) generic_entries "$HOME/.cache" dot ;;
        huggingface)
            path="$HOME/.cache/huggingface"; measure "$path"; cleanup tree "$path" ;;
        repo-artifacts) repo_artifacts ;;
        logs)
            path="$HOME/Library/Logs"
            safe_path "$path" || return 0
            [[ -d "$path" ]] || { measure "$path"; return 0; }
            printf '  %s 配下: -type f -mtime +14 のみ\n' "$path"
            while IFS= read -r -d '' child; do
                [[ -n "$child" ]] || return 1
                measure "$child"; cleanup file "$child" || failed=1
            done < <(find -P "$path" -type f -mtime +14 -print0 || printf '\0')
            return "$failed" ;;
    esac
}

# Prevent mise shims from installing runtimes while inspecting tools.
export MISE_AUTO_INSTALL=0 MISE_NOT_FOUND_AUTO_INSTALL=0
if [[ $APPLY -eq 1 ]]; then
    printf 'モード: APPLY\n\n実行前: df -h /System/Volumes/Data\n'
    BEFORE=$(df -h /System/Volumes/Data) || die '実行前の df を取得できません'
    printf '%s\n' "$BEFORE"
else
    printf 'モード: dry-run（削除なし）\n'
fi
for category in $CATEGORIES; do
    if [[ -n "$ONLY" ]]; then contains "$ONLY" "$category" || continue
    elif [[ "$category" == huggingface || "$category" == repo-artifacts ]]; then continue; fi
    contains "$SKIP" "$category" && continue
    if run_category "$category"; then :
    else warn "$category が失敗しました。次のカテゴリへ進みます。"; fi
done
printf '\n見込み削減量の上限（測定できた対象のみ）: %s\n' "$(human_size "$TOTAL_KIB")"
printf '共有ブロック・使用中ファイル・ツールの保持条件により実際の空き容量増加とは異なります。\n'
if [[ $APPLY -eq 1 ]]; then
    printf '\n実行前: df -h /System/Volumes/Data\n%s\n' "$BEFORE"
    printf '\n実行後: df -h /System/Volumes/Data\n'
    df -h /System/Volumes/Data || warn '実行後の df を取得できません'
fi
printf '警告: %s 件\n' "$WARNINGS"
