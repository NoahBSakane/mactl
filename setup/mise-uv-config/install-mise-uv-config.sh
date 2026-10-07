#!/bin/bash
# Installs (or re-installs) this Mac's mise/uv version-management guardrails.
# See ./mise-uv-config.md for the full rationale; short version: mise is
# meant to be the sole runtime-toolchain manager, but uv can silently fall
# back to downloading its own Python if left on defaults. This script closes
# that hole with two independent settings:
#
#   1. ~/.zshrc: export UV_PYTHON_PREFERENCE=only-system, inserted right
#      after the `mise activate zsh` line so it's active in every shell mise
#      manages. Skipped (not duplicated) if UV_PYTHON_PREFERENCE already
#      appears anywhere in the file.
#   2. ~/.config/mise/config.toml: `locked = true` and
#      `idiomatic_version_file_enable_tools = ["python"]` under [settings].
#      Applied via `mise settings set`, which edits only the [settings]
#      table in place — unlike the cp-based installers elsewhere in this
#      repo, config.toml also carries this machine's own [tools] versions,
#      so it can't be a straight overwrite target.
#
# Requires mise to already be installed and activated in ~/.zshrc (this
# script only layers the guardrails on top, it doesn't bootstrap mise
# itself).
#
# Portable across any Mac/user account: everything below resolves through
# $HOME, no hardcoded paths. Safe to re-run any time.

set -euo pipefail

ZSHRC="$HOME/.zshrc"
MISE_ANCHOR='eval "$(~/.local/bin/mise activate zsh)"'

if ! command -v mise >/dev/null 2>&1; then
    echo "error: mise not found on PATH — install/activate mise first" >&2
    exit 1
fi

if [[ ! -f "$ZSHRC" ]]; then
    echo "error: $ZSHRC not found" >&2
    exit 1
fi

if grep -q "UV_PYTHON_PREFERENCE" "$ZSHRC"; then
    echo "skip: UV_PYTHON_PREFERENCE already present in $ZSHRC"
else
    LINE="$(grep -nF "$MISE_ANCHOR" "$ZSHRC" | head -1 | cut -d: -f1)"
    if [[ -z "$LINE" ]]; then
        echo "error: mise activate line not found in $ZSHRC — set up mise" >&2
        echo "  itself in this file first, then re-run this script." >&2
        exit 1
    fi

    BLOCKFILE="$(mktemp)"
    trap 'rm -f "$BLOCKFILE"' EXIT
    cat > "$BLOCKFILE" <<'EOF'

# uvはデフォルトでPython本体を自前管理(pyenv的な内蔵ダウンロード機能)しようとし、
# miseが管理するPythonより自前キャッシュを優先することがある(mise/uvのPython守備範囲が重複する唯一の点)。
# ここを system 優先にして、mise管理下のPythonを常に使わせる。
# 特定プロジェクトだけuv自前管理に戻したい場合は、そのプロジェクトのmise.tomlに
#   [env]
#   UV_PYTHON_PREFERENCE = "managed"
# を書けば、ここでのグローバル設定を上書きできる(動作確認済み)。
export UV_PYTHON_PREFERENCE=only-system
EOF

    cp "$ZSHRC" "$ZSHRC.bak.$(date +%Y%m%d%H%M%S)"
    sed -i '' "${LINE}r $BLOCKFILE" "$ZSHRC"
    echo "added: UV_PYTHON_PREFERENCE=only-system to $ZSHRC (backup saved alongside it)"
fi

mise settings set locked true
mise settings set idiomatic_version_file_enable_tools python

echo
echo "mise settings (~/.config/mise/config.toml):"
echo "  locked = $(mise settings get locked)"
echo "  idiomatic_version_file_enable_tools = $(mise settings get idiomatic_version_file_enable_tools)"
echo
echo "Restart your shell (or 'source ~/.zshrc') for the UV_PYTHON_PREFERENCE change to take effect."
