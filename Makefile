SHELL := /bin/zsh
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DELETE_ON_ERROR:
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules

# This Makefile has no includes. Keep MAKEFILE_LIST intact: the path may contain spaces.
SELF := $(shell /bin/zsh -c 'print -r -- "$${1:A}"' -- "$(MAKEFILE_LIST)")
REPO_ROOT := $(shell dirname "$(SELF)")
PROJECT_ROOT := $(if $(MACTL_PROJECT_ROOT),$(MACTL_PROJECT_ROOT),$(HOME)/Repos)
EXCLUDED_PROJECT_ROOT := $(if $(MACTL_EXCLUDED_PROJECT_ROOT),$(MACTL_EXCLUDED_PROJECT_ROOT),$(HOME)/Repos/fan-n-sakane)
export MACTL_PROJECT_ROOT := $(PROJECT_ROOT)
export MACTL_EXCLUDED_PROJECT_ROOT := $(EXCLUDED_PROJECT_ROOT)
PROJECT_RUNNER := $(REPO_ROOT)/maintain/project-maintain.zsh
COMMANDS := $(REPO_ROOT)/maintain/COMMANDS.md
CLEANUP := $(REPO_ROOT)/cleanup/mac-cleanup.sh
FIREWALL := /usr/libexec/ApplicationFirewall/socketfilterfw
MISE := $(HOME)/.local/bin/mise
GMAKE := $(shell if [[ -x /opt/homebrew/opt/make/libexec/gnubin/make ]]; then print -r -- /opt/homebrew/opt/make/libexec/gnubin/make; else command -v gmake; fi)
SUDO := /usr/bin/sudo

.PHONY: help commands maintain plan update-system update-tools ensure-firewall clean projects report setup doctor check push-setup

help:
	@printf '%s\n' \
	  'mactl                    対話確認後、更新・整理・監査を一括実行' \
	  'mactl setup              設定インストーラ4本を順番に実行' \
	  'mactl doctor             必要なツール(jq・python3 ほか)の有無を確認' \
	  'mactl check              ai-agent-config のテストと公開前の検査を実行' \
	  'mactl push-setup         このクローンを NoahBSakane で push できるよう設定' \
	  'mactl clean --deep       詳細清掃（既定dry-run、--listでカテゴリ表示）' \
	  'mactl plan               変更せず、更新候補と監査結果を確認' \
	  'mactl clean              許可リスト済みの単純キャッシュだけ整理' \
	  'mactl projects           .mac-maintain対象を更新・監査・検証' \
	  'mactl report             Macと開発環境の状態だけ表示' \
	  'mactl commands           保存済みのコマンド一覧を表示' \
	  'mactl -y                 対話確認を省略して一括実行'

commands:
	@sed -n '1,260p' "$(COMMANDS)"

maintain:
	@printf '%s\n' \
	  '実行内容: Homebrew/App Store/mise/言語ツール更新、' \
	  '安全なキャッシュ整理、ファイアウォール確認、' \
	  '.mac-maintain対象の依存最新版化・監査・テスト・ビルド。' \
	  'LINE・UTM・壁紙・Claude・Codexは単純キャッシュだけ削除します。'
	@if [[ "$(YES)" != '1' ]]; then
	  printf '続行しますか？ [y/N] '
	  read -r reply
	  [[ "$$reply" == [yY] ]] || { printf '%s\n' '中止しました。'; exit 0; }
	fi
	@printf '%s\n' '管理者認証を最初に一度だけ行います。'
	@$(SUDO) -v
	@(
	  while $(SUDO) -n -v >/dev/null 2>&1; do
	    /bin/sleep 30
	  done
	) &
	@sudo_keepalive_pid=$$!
	@stop_sudo_keepalive() {
	  trap - EXIT INT TERM HUP
	  if [[ -n "$${sudo_keepalive_pid:-}" ]]; then
	    /bin/kill "$$sudo_keepalive_pid" 2>/dev/null || true
	    wait "$$sudo_keepalive_pid" 2>/dev/null || true
	  fi
	  $(SUDO) -k
	}
	@trap stop_sudo_keepalive EXIT
	@trap 'stop_sudo_keepalive; exit 130' INT
	@trap 'stop_sudo_keepalive; exit 143' TERM
	@trap 'stop_sudo_keepalive; exit 129' HUP
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" update-system
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" update-tools
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" ensure-firewall
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" clean
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" projects
	@"$(GMAKE)" --no-print-directory -f "$(SELF)" report

plan:
	@printf '%s\n' '== Homebrew =='
	@HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula --dry-run
	@HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask --greedy --dry-run
	@printf '%s\n' '== App Store =='
	@MAS_NO_AUTO_INDEX=1 mas outdated || true
	@printf '%s\n' '== mise =='
	@"$(MISE)" upgrade --bump --dry-run || true
	@printf '%s\n' '== npm / Ruby / uv =='
	@"$(MISE)" exec --fresh-env -- npm outdated --global || true
	@"$(MISE)" exec --fresh-env -- gem outdated || true
	@"$(MISE)" exec --fresh-env -- uv tool list
	@printf '%s\n' '== Opt-in project updates =='
	@found=0
	@result=0
	@while IFS= read -r -d '' marker; do
	  found=1
	  "$(PROJECT_RUNNER)" --plan "$${marker:h}" || result=1
	done < <(/usr/bin/find "$(PROJECT_ROOT)" \
	  \( -path "$(EXCLUDED_PROJECT_ROOT)" -o -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
	  -name .mac-maintain -type f -print0)
	@if (( ! found )); then printf '%s\n' 'No .mac-maintain projects found.'; fi
	@exit $$result

update-system:
	@printf '%s\n' '== Homebrew formulae =='
	@brew update
	@brew upgrade --formula --yes
	@codex_running=0
	@if /bin/ps -axo ucomm= | /usr/bin/awk '$$1 == "ChatGPT" { found=1 } END { exit !found }'; then
	  codex_running=1
	  printf '%s\n' 'Codex is running; its Homebrew adoption or upgrade is deferred until it is closed.'
	elif [[ -d '/Applications/ChatGPT.app' ]] && ! brew list --cask chatgpt >/dev/null 2>&1; then
	  printf '%s\n' 'Adopting the existing Codex desktop app as the Homebrew chatgpt cask...'
	  if ! brew install --cask --adopt chatgpt; then
	    printf '%s\n' 'The Homebrew release differs; replacing only the app bundle without zapping user data...'
	    brew install --cask --force chatgpt
	  fi
	fi
	@printf '%s\n' '== Homebrew casks =='
	@if (( codex_running )); then
	  outdated_casks=()
	  while IFS= read -r cask; do
	    [[ -n "$$cask" && "$$cask" != chatgpt ]] && outdated_casks+=("$$cask")
	  done < <(brew outdated --cask --greedy --quiet)
	  if (( $${#outdated_casks[@]} )); then
	    brew upgrade --cask --greedy --yes "$${outdated_casks[@]}"
	  else
	    printf '%s\n' 'All non-Codex casks are up to date.'
	  fi
	else
	  brew upgrade --cask --greedy --yes
	fi
	@printf '%s\n' '== App Store =='
	@$(SUDO) -n /usr/bin/env MAS_NO_AUTO_INDEX=1 /opt/homebrew/bin/mas update

update-tools:
	@printf '%s\n' '== mise and language runtimes =='
	@current_mise_version="$$("$(MISE)" --version | /usr/bin/awk '{print $$1}')"
	@latest_mise_url=''
	@if latest_mise_url="$$('/usr/bin/curl' -fsSL -o /dev/null -w '%{url_effective}' https://github.com/jdx/mise/releases/latest)"; then
	  latest_mise_version="$${latest_mise_url##*/v}"
	  if [[ "$$latest_mise_version" == <->.<->.<-> ]]; then
	    if [[ "$$latest_mise_version" == "$$current_mise_version" ]]; then
	      printf 'mise %s is already up to date.\n' "$$current_mise_version"
	    else
	      mise_update_output=''
	      if mise_update_output="$$("$(MISE)" self-update "$$latest_mise_version" --yes 2>&1)"; then
	        printf '%s\n' "$$mise_update_output"
	      else
	        printf 'Warning: mise self-update to %s was skipped; continuing with %s.\n' \
	          "$$latest_mise_version" "$$current_mise_version" >&2
	        [[ -n "$$mise_update_output" ]] && printf '%s\n' "$$mise_update_output" >&2
	      fi
	    fi
	  else
	    printf 'Warning: unable to parse the latest mise version; continuing with %s.\n' \
	      "$$current_mise_version" >&2
	  fi
	else
	  printf 'Warning: unable to check the latest mise version; continuing with %s.\n' \
	    "$$current_mise_version" >&2
	fi
	@"$(MISE)" upgrade --bump --yes --no-prune
	@"$(MISE)" lock --global --platform macos-arm64 --yes
	@printf '%s\n' '== language package managers =='
	@"$(MISE)" exec --fresh-env -- npm install --global npm@latest
	@"$(MISE)" exec --fresh-env -- uv tool upgrade --all
	@"$(MISE)" exec --fresh-env -- gem update --system --no-document
	@"$(MISE)" exec --fresh-env -- gem install bundler --no-document

ensure-firewall:
	@if "$(FIREWALL)" --getglobalstate | grep -q 'State = 1'; then
	  printf '%s\n' 'Firewall: enabled'
	else
	  $(SUDO) -n "$(FIREWALL)" --setglobalstate on
	  "$(FIREWALL)" --getglobalstate
	fi

clean:
	@printf '%s\n' '== Safe cache cleanup =='
	@"$(MISE)" exec --fresh-env -- pnpm store prune
	@"$(MISE)" exec --fresh-env -- npm cache verify
	@"$(MISE)" exec --fresh-env -- uv cache prune
	@brew cleanup --prune=all
	@printf '%s\n' '== Allowlisted app caches =='
	@"$(CLEANUP)" --apply --only app-caches

projects:
	@printf '%s\n' '== Opt-in project maintenance =='
	@found=0
	@result=0
	@while IFS= read -r -d '' marker; do
	  found=1
	  "$(PROJECT_RUNNER)" "$${marker:h}" || result=1
	done < <(/usr/bin/find "$(PROJECT_ROOT)" \
	  \( -path "$(EXCLUDED_PROJECT_ROOT)" -o -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
	  -name .mac-maintain -type f -print0)
	@if (( ! found )); then printf '%s\n' 'No .mac-maintain projects found.'; fi
	@exit $$result

report:
	@printf '%s\n' '== Disk =='
	@df -h /System/Volumes/Data
	@printf '%s\n' '== macOS updates =='
	@softwareupdate --list
	@printf '%s\n' '== Homebrew =='
	@HOMEBREW_NO_AUTO_UPDATE=1 brew doctor || true
	@HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --greedy || true
	@printf '%s\n' '== mise =='
	@mise doctor
	@mise outdated || true
	@printf '%s\n' '== Security =='
	@"$(FIREWALL)" --getglobalstate
	@if [[ -d '/Applications/ChatGPT.app' ]] && ! brew list --cask chatgpt >/dev/null 2>&1; then
	  if /bin/ps -axo ucomm= | /usr/bin/awk '$$1 == "ChatGPT" { found=1 } END { exit !found }'; then
	    printf '%s\n' 'Codex desktop: 終了後の一括実行でHomebrew管理へ引き継ぎます。'
	  else
	    printf '%s\n' 'Codex desktop: 次回の一括実行でHomebrew管理へ引き継ぎます。'
	  fi
	fi
	@if brew list --cask qbittorrent >/dev/null 2>&1; then
	  printf '%s\n' '注意: qBittorrentは自動更新対象ですが、Homebrewで非推奨です。'
	fi

setup:
	@printf '%s\n' '実行内容（この順で実行し、失敗したら停止）:' \
	  '  1. $(REPO_ROOT)/setup/mise-uv-config/install-mise-uv-config.sh' \
	  '  2. $(REPO_ROOT)/setup/ai-agent-config/install.sh' \
	  '  3. $(REPO_ROOT)/setup/login-items/install-login-items-runner.sh' \
	  '  4. $(REPO_ROOT)/setup/cursor-sidebar-icon-patch/install-cursor-sidebar-icon-patch.sh'
	@if [[ "$(YES)" != '1' ]]; then
	  printf '続行しますか？ [y/N] '
	  read -r reply
	  [[ "$$reply" == [yY] ]] || { printf '%s\n' '中止しました。'; exit 0; }
	fi
	@/bin/bash "$(REPO_ROOT)/setup/mise-uv-config/install-mise-uv-config.sh"
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/install.sh" -y
	@/bin/bash "$(REPO_ROOT)/setup/login-items/install-login-items-runner.sh"
	@/bin/bash "$(REPO_ROOT)/setup/cursor-sidebar-icon-patch/install-cursor-sidebar-icon-patch.sh"

doctor:
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/doctor.sh"

check:
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/tests/hooks-test.sh"
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/tests/install-test.sh"
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/tests/public-check-test.sh"
	@/bin/bash "$(REPO_ROOT)/setup/ai-agent-config/tests/handoff-exclude-test.sh"
	@python3 "$(REPO_ROOT)/setup/ai-agent-config/public-check.py"

push-setup:
	@/bin/bash "$(REPO_ROOT)/setup-git-account.sh"
