# Claude Codeが使用上限で使えないとき

## 1. 待つか、代行させるか

メッセージ「You've hit your session limit · resets 3:45pm」にリセット時刻が出る。

- **既定は待機。** 対話セッション(claude.ai契約)では、設定 `autoContinueAtUsageLimit`(既定で有効)により、セッションを開いたままリセット後に中断したタスクを自動で再開できる(`/goal` 中ならその目標へ戻る)。ただし `/config` の「Continue automatically at usage limit」の行は環境によって出ず(claude.ai の Team 契約のこのMacでは出ない)、効くかは確認できていないので、当てにせず、待てないときは下の手順で別のエージェントへ回す。`claude -p` の非対話実行がこの待機に対応するかは、文書に記載が無い。
- **待たずに代行させる条件:** リセットまでの時間が長い(目安: 1時間超)、または緊急度が高い。

## 2. 代行の手順

1. Claude Code側で、直前の状態を `.agent-handoff/STATE.md` に書けているか確認する(上限到達後は書けない。書いていなければ、会話履歴や `git status` / `git diff` から再構築する)。
2. 代行先を選ぶ。既定の優先順は **Codex → agy → Muse**(Grokは導入されていれば台帳の適切用途に従う)。順位の根拠と確認日は、台帳の「代行先の優先順位」にある。`agents-probe.sh` で `ready` のものから選ぶ(`limit`=使用上限中、`no-auth`=未認証 は代行先にしない。例えばCodexが上限中なら、次の優先順位のagyにする)。
3. `~/.knowledge/bin/agent-takeover.sh <agent> [作業ディレクトリ]` で、そのエージェントを対話モードで起動する(`<agent>` は `agents.conf` に `interactive` がある任意のエージェント)。起動時のプロンプトは「`~/AGENTS.md` の共通ルールと `.agent-handoff/STATE.md` を読み、司令塔として作業を引き継げ」。
4. 代行側は、共通ルール(`AGENTS.md`)、共有skills(`~/.agents/skills`)、台帳を読んで、Claude Codeと同じ手順で動く。構成承認・レビュー・品質ゲート・完了判定も同じ。ただし、hookによる強制は、そのエージェントにhookが配線されている場合に限られる(`agents-probe.sh` の出力と台帳で確認)。配線が無い間は、助言(この手順)に従って自律的に守る。
5. Claude Codeが使えるようになったら、`STATE.md` を渡して戻す。

## 3. 代行中に委譲できないもの

代行側は、自分自身には委譲しない。Claude Codeは(上限中なので)委譲先にならない。残りの `ready` なエージェントから、台帳の適切用途で選ぶ。
