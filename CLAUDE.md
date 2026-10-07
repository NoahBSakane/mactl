<!-- markdownlint-disable-file MD041 -->
@AGENTS.md

## Claude Code専用

- 指示ファイルの食い違いを調べて取り込むときは `/reconcile-agent-config`(`.claude/skills/reconcile-agent-config/`)を使う。
- このrepoの編集は、構成承認(共通ルールの司令塔プロトコル)の対象。スクリプト類(hook・install・diff・probe)は「既存の規約に合わせて直す」作業なので、Codexが既定の委譲先。
