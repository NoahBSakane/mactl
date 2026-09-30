#!/bin/zsh
set -u
setopt pipefail

mode=run
if [[ "${1:-}" == '--plan' ]]; then
  mode=plan
  shift
fi

project="${1:-}"
if [[ -z "$project" ]]; then
  print -u2 'A project path is required.'
  exit 2
fi
project="${project:A}"
if [[ ! -f "$project/.mac-maintain" || -L "$project/.mac-maintain" ]]; then
  print -u2 'A regular .mac-maintain marker is required.'
  exit 2
fi
project_root="${MACTL_PROJECT_ROOT:-$HOME/Repos}"
excluded_project_root="${MACTL_EXCLUDED_PROJECT_ROOT:-$HOME/Repos/fan-n-sakane}"
project_root="${project_root:A}"
excluded_project_root="${excluded_project_root:A}"
case "$project" in
  "$excluded_project_root"|"$excluded_project_root"/*)
    print -u2 "Refusing the excluded project tree: $excluded_project_root"
    exit 2
    ;;
  "$project_root"/*) ;;
  *)
    print -u2 "Refusing project outside $project_root: $project"
    exit 2
    ;;
esac

cd "$project"
printf '\n[%s]\n' "$project"
report_path="$project/CODE_UPDATE_REQUIRED.md"

initial_mise_env="$(MISE_LOCKED=0 mise env --shell zsh)"
if (( $? != 0 )); then
  print -u2 'Unable to resolve the project runtime environment.'
  exit 2
fi
eval "$initial_mise_env"

has_script() {
  node -e 'const s=require("./package.json").scripts||{}; process.exit(Object.hasOwn(s, process.argv[1]) ? 0 : 1)' "$1"
}

run_node_checks() {
  local manager="$1"
  local script
  for script in typecheck test build; do
    if has_script "$script"; then
      run_checked "$manager run $script" "$manager" run "$script"
    fi
  done
}

run_audit() {
  local label="$1"
  shift
  printf '%s\n' "-- $label"
  "$@" 2>&1 | tee "$failure_log"
  local command_status=$pipestatus[1]
  if (( command_status != 0 )); then
    {
      printf '\n-- %s --\n' "$label"
      cat "$failure_log"
    } >> "$audit_log"
    audit_failed=1
  fi
}

deno_has_task() {
  local task_name="$1"
  local task_list
  task_list="$(deno task 2>&1)" || return 1
  grep -Eq "^- ${task_name}( \\(|$)" <<< "$task_list"
}

run_deno_checks() {
  local -a source_files=()
  local source_file
  if deno_has_task check; then
    run_checked 'Deno project checks' deno task check
    return
  fi
  while IFS= read -r -d '' source_file; do
    source_files+=("$source_file")
  done < <(/usr/bin/find . \
    \( -name .git -o -name node_modules -o -name .venv -o -name target -o \
       -name dist -o -name build -o -name coverage -o -name vendor -o -name .wrangler \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
      -o -name '*.mts' -o -name '*.cts' -o -name '*.mjs' -o -name '*.cjs' \) -print0)
  if (( ${#source_files[@]} )); then
    run_checked 'Deno source checks' deno check "${source_files[@]}"
  fi
}

if [[ "$mode" == plan ]]; then
  detected=0
  if [[ -f mise.toml ]]; then
    mise upgrade --local --bump --dry-run || true
  fi
  if [[ -f pnpm-lock.yaml && -f package.json ]]; then
    detected=1
    pnpm outdated || true
    pnpm audit --audit-level moderate || true
  elif [[ -f package-lock.json && -f package.json ]]; then
    detected=1
    npm outdated || true
    npm audit --audit-level=moderate || true
  fi
  if [[ -f uv.lock && -f pyproject.toml ]]; then
    detected=1
    uv tree --outdated || true
  fi
  if [[ -f Cargo.lock && -f Cargo.toml ]]; then
    detected=1
    cargo update --dry-run || true
  fi
  if [[ -f go.sum && -f go.mod ]]; then
    detected=1
    go list -m -u all || true
  fi
  if [[ -f Gemfile.lock && -f Gemfile ]]; then
    detected=1
    bundle outdated || true
  fi
  if [[ -f deno.lock && ( -f deno.json || -f deno.jsonc ) ]]; then
    detected=1
    deno outdated --recursive || true
    deno audit --level=moderate || true
  fi
  if [[ -f .terraform.lock.hcl ]] && /usr/bin/find . -maxdepth 2 -name '*.tf' -print -quit | grep -q .; then
    detected=1
    terraform providers || true
  fi
  if [[ -f buf.lock && ( -f buf.yaml || -f buf.work.yaml ) ]]; then
    detected=1
    buf dep graph || true
  fi
  if (( ! detected )); then
    print -u2 'No supported locked dependency environment found.'
    exit 2
  fi
  exit 0
fi

backup_dir="$(mktemp -d /tmp/mac-maintain.project.XXXXXX)"
backup_files="$backup_dir/files"
backup_list="$backup_dir/files.list"
failure_log="$backup_dir/last-command.log"
audit_log="$backup_dir/audit.log"
mkdir -p "$backup_files"
: > "$backup_list"
: > "$audit_log"

while IFS= read -r -d '' file; do
  rel="${file#./}"
  mkdir -p "$backup_files/${rel:h}"
  cp -p "$rel" "$backup_files/$rel"
  printf '%s\0' "$rel" >> "$backup_list"
done < <(/usr/bin/find . \
  \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
  -type f \( \
    -name package.json -o -name pnpm-lock.yaml -o -name pnpm-workspace.yaml -o \
    -name package-lock.json -o -name npm-shrinkwrap.json -o \
    -name pyproject.toml -o -name uv.lock -o \
    -name Cargo.toml -o -name Cargo.lock -o \
    -name go.mod -o -name go.sum -o \
    -name Gemfile -o -name Gemfile.lock -o \
    -name mise.toml -o -name mise.lock -o \
    -name deno.json -o -name deno.jsonc -o -name deno.lock -o \
    -name .terraform.lock.hcl -o -name buf.yaml -o -name buf.work.yaml -o -name buf.lock \
  \) -print0)

cleanup_backup() {
  if [[ "$backup_dir" == /tmp/mac-maintain.project.* && -d "$backup_dir" ]]; then
    /bin/rm -rf -- "$backup_dir"
  fi
}

restore_manifests() {
  print -u2 'Verification failed; restoring manifests and lockfiles.'
  local restore_failed=0
  local current_file
  local rel
  while IFS= read -r -d '' current_file; do
    rel="${current_file#./}"
    if [[ ! -f "$backup_files/$rel" ]]; then
      /bin/rm -f -- "$rel" || restore_failed=1
    fi
  done < <(/usr/bin/find . \
    \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
    -type f \( \
      -name package.json -o -name pnpm-lock.yaml -o -name pnpm-workspace.yaml -o \
      -name package-lock.json -o -name npm-shrinkwrap.json -o \
      -name pyproject.toml -o -name uv.lock -o \
      -name Cargo.toml -o -name Cargo.lock -o \
      -name go.mod -o -name go.sum -o \
      -name Gemfile -o -name Gemfile.lock -o \
      -name mise.toml -o -name mise.lock -o \
      -name deno.json -o -name deno.jsonc -o -name deno.lock -o \
      -name .terraform.lock.hcl -o -name buf.yaml -o -name buf.work.yaml -o -name buf.lock \
    \) -print0)
  while IFS= read -r -d '' rel; do
    mkdir -p "${rel:h}"
    cp -p "$backup_files/$rel" "$rel" || restore_failed=1
  done < "$backup_list"
  local restored_mise_env
  restored_mise_env="$(MISE_LOCKED=0 mise env --shell zsh 2>/dev/null)" || true
  if [[ -n "$restored_mise_env" ]]; then
    eval "$restored_mise_env"
  fi
  if [[ -f pnpm-lock.yaml && -f package.json ]]; then
    pnpm install --frozen-lockfile || restore_failed=1
  elif [[ -f package-lock.json && -f package.json ]]; then
    npm ci || restore_failed=1
  fi
  if [[ -f uv.lock && -f pyproject.toml ]]; then
    uv sync --frozen || restore_failed=1
  fi
  if [[ -f Gemfile.lock && -f Gemfile ]]; then
    bundle install || restore_failed=1
  fi
  if [[ -f deno.lock && ( -f deno.json || -f deno.jsonc ) ]]; then
    deno install --frozen || restore_failed=1
  fi
  return $restore_failed
}

write_update_report() {
  local failed_stage="$1"
  local rollback_state="$2"
  shift 2
  local command_text
  command_text="${(j: :)${(q)@}}"
  {
    printf '%s\n' '# コード修正が必要です'
    printf '%s\n' '<!-- generated-by: mac-maintain -->'
    printf '\nGenerated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n最新ランタイムまたは依存関係への更新が **%s** で失敗しました。\n' "$failed_stage"
    case "$rollback_state" in
      restored)
        printf '%s\n' 'manifestとlockfileは更新前へ復元済みで、プロジェクトは従来の依存関係で動作します。'
        ;;
      incomplete)
        printf '%s\n' 'manifestまたは依存環境の自動復元が完了しませんでした。差分を確認して手動での復元が必要です。'
        ;;
      retained)
        printf '%s\n' '依存関係の更新は保持されていますが、脆弱性監査への対応が必要です。'
        ;;
    esac
    printf '%s\n' 'CodexやAIリファクタリングは自動起動していません。'
    printf '\n## Failed command\n\n    %s\n' "$command_text"
    if [[ -s "$failure_log" ]]; then
      printf '%s\n' '' '## Last output' ''
      tail -80 "$failure_log" | sed 's/^/    /'
    fi
    printf '%s\n' '' '## 次の対応' '' \
      'ランタイムまたは依存関係の移行内容を確認し、必要ならソースコードを修正してから再実行してください。' '' \
      '    mactl projects'
  } > "$report_path"
  print -u2 "Created: $report_path"
}

run_checked() {
  local label="$1"
  shift
  printf '%s\n' "-- $label"
  "$@" 2>&1 | tee "$failure_log"
  local command_status=$pipestatus[1]
  if (( command_status != 0 )); then
    local rollback_state=restored
    restore_manifests || rollback_state=incomplete
    write_update_report "$label" "$rollback_state" "$@"
    cleanup_backup
    exit 1
  fi
}

interrupt_rollback() {
  local exit_status="$1"
  trap - INT TERM
  print -u2 'Maintenance interrupted; restoring manifests and lockfiles.'
  restore_manifests || print -u2 'Automatic dependency restoration was incomplete.'
  cleanup_backup
  exit "$exit_status"
}

trap cleanup_backup EXIT
trap 'interrupt_rollback 130' INT
trap 'interrupt_rollback 143' TERM
detected=0
audit_failed=0

if [[ -f mise.toml ]]; then
  run_checked 'project runtime updates' env MISE_LOCKED=0 mise upgrade --local --bump --yes --no-prune
  run_checked 'project runtime lock' env MISE_LOCKED=0 mise lock --platform macos-arm64 --yes
  refreshed_mise_env="$(mise env --shell zsh 2>"$failure_log")"
  if (( $? != 0 )); then
    rollback_state=restored
    restore_manifests || rollback_state=incomplete
    write_update_report 'project runtime activation' "$rollback_state" mise env --shell zsh
    cleanup_backup
    exit 1
  fi
  if [[ -s "$failure_log" ]]; then
    cat "$failure_log" >&2
  fi
  eval "$refreshed_mise_env"
fi

if [[ -f pnpm-lock.yaml && -f package.json ]]; then
  detected=1
  run_checked 'pnpm latest dependencies' pnpm update --latest
  if [[ -f pnpm-workspace.yaml ]] && grep -q '^[[:space:]]*packages:' pnpm-workspace.yaml; then
    run_checked 'pnpm workspace latest dependencies' pnpm --recursive update --latest
  fi
  run_audit 'pnpm dependency audit' pnpm audit --audit-level moderate
  run_node_checks pnpm
elif [[ -f package-lock.json && -f package.json ]]; then
  detected=1
  run_checked 'npm latest dependency ranges' npm exec --yes npm-check-updates@latest -- -u
  run_checked 'npm install' npm install
  run_audit 'npm dependency audit' npm audit --audit-level=moderate
  run_node_checks npm
fi

if [[ -f uv.lock && -f pyproject.toml ]]; then
  detected=1
  run_checked 'uv latest dependencies' uv lock --upgrade
  run_checked 'uv sync' uv sync
  if [[ -d tests ]] && rg -q 'pytest' pyproject.toml; then
    run_checked 'pytest' uv run pytest
  fi
  if rg -q 'ruff' pyproject.toml; then
    run_checked 'ruff' uv run ruff check .
  fi
  run_audit 'Python dependency audit' uvx pip-audit
fi

if [[ -f Cargo.lock && -f Cargo.toml ]]; then
  detected=1
  run_checked 'cargo compatible dependency updates' cargo update
  run_checked 'cargo tests' cargo test --all-targets
fi

if [[ -f go.sum && -f go.mod ]]; then
  detected=1
  run_checked 'Go dependency updates' go get -u ./...
  run_checked 'Go module tidy' go mod tidy
  run_checked 'Go tests' go test ./...
fi

if [[ -f Gemfile.lock && -f Gemfile ]]; then
  detected=1
  run_checked 'Bundler dependency updates' bundle update
  if [[ -f Rakefile ]]; then
    run_checked 'Ruby tests' bundle exec rake test
  fi
fi

if [[ -f deno.lock && ( -f deno.json || -f deno.jsonc ) ]]; then
  detected=1
  run_checked 'Deno latest dependencies' deno outdated --update --latest --recursive --minimum-dependency-age 1440
  run_checked 'Deno dependency install' deno install
  run_audit 'Deno dependency audit' deno audit --level=moderate
  run_deno_checks
  if deno_has_task test; then
    run_checked 'Deno tests' deno task test
  elif [[ -d tests || -d test ]]; then
    run_checked 'Deno tests' deno test
  fi
  if deno_has_task build; then
    run_checked 'Deno build' deno task build
  fi
fi

if [[ -f .terraform.lock.hcl ]] && /usr/bin/find . -maxdepth 2 -name '*.tf' -print -quit | grep -q .; then
  detected=1
  run_checked 'Terraform provider updates' terraform init -backend=false -upgrade -input=false
  run_checked 'Terraform validation' terraform validate
fi

if [[ -f buf.lock && ( -f buf.yaml || -f buf.work.yaml ) ]]; then
  detected=1
  run_checked 'Buf dependency updates' buf dep update
  run_checked 'Buf lint' buf lint
fi

if (( ! detected )); then
  print -u2 'No supported locked dependency environment found.'
  exit 2
fi

if (( audit_failed )); then
  if [[ -s "$audit_log" ]]; then
    cp "$audit_log" "$failure_log"
  else
    printf '%s\n' 'A dependency audit still reports vulnerabilities.' > "$failure_log"
  fi
  write_update_report 'dependency audit' retained 'rerun the package-manager audit shown above'
  cleanup_backup
  trap - EXIT INT TERM
  print -u2 'Dependencies were updated and checks passed, but an audit still reports vulnerabilities.'
  exit 1
fi
cleanup_backup
trap - EXIT INT TERM
if [[ -f "$report_path" ]] && grep -q '<!-- generated-by: mac-maintain -->' "$report_path"; then
  /bin/rm -f -- "$report_path"
fi
printf '%s\n' 'Dependency update and verification completed.'
