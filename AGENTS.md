# Cross-project notes for AI agents

Lessons learned while working across n_sakane's projects, meant to be useful
regardless of which AI agent/tool is currently working in a given repo. Two kinds of
content live here:

1. **Truly universal principles** — apply no matter what the project even is (not
   tied to any technology or domain). Written out in full, inline, below.
2. **An index of domain-specific knowledge files** — e.g. "if you're touching Google
   Apps Script / clasp, see `~/.knowledge/gas-apps-script.md`". The actual lessons for
   a given technology live in their own file under `~/.knowledge/`, not inlined here,
   so that a project unrelated to that technology (e.g. a writing project) never has
   to read past a one-line pointer it can ignore. Each `~/.knowledge/*.md` file is
   itself cross-repo within its domain (e.g. useful to any GAS/clasp project, not just
   the one that happened to surface the lesson) — link to the originating repo's own
   docs from there for project-specific setup detail.

Keep entries short and dated regardless of which tier they belong to.

## Universal principles

### 2026-08-12 — Read `CODE_UPDATE_REQUIRED.md` at the start of any session

If a project's root has a `CODE_UPDATE_REQUIRED.md`, read it before doing anything
else and treat it as an unresolved runtime/dependency migration that needs
addressing.

### 2026-08-19 — Default to building your own capability, not offloading to the human

When a task needs verification/execution I can't currently do myself (e.g. running
code in an environment I don't have direct access to), the default move is to find
and fix *my own* missing capability first, not to hand the whole task to the human
and ask them to report back results. Concretely: diagnose why I can't do it, fix what
I can fix myself, and reduce the ask to the smallest possible human-only step — one
that's genuinely irreducible, like clicking "Allow" on an OAuth consent screen or
pasting back a post-redirect URL (something no amount of CLI/API work substitutes
for). The goal is durable self-sufficient coverage for *this* and future sessions,
not a one-off answer.

This doesn't mean never asking anything — real decisions that only the human can
make (tradeoffs, preferences, "which of these should I do") still belong to them, and
actions that are risky/destructive/outward-facing still warrant confirmation before
acting. The distinction is: don't ask them to do *verification legwork* that you could
instead build the capability to do yourself.

### 2026-08-19 — Division of labor between this file, `~/.knowledge/`, and a `CLAUDE.md`

Three tiers, by audience:

- `~/AGENTS.md` (this file): universal principles in full, plus a one-line index
  entry per domain-specific knowledge file. Not the place for a specific technology's
  gotchas — see below.
- `~/.knowledge/<topic>.md`: the substantive home for anything tied to a specific
  technology/domain (a language, a platform, a tool) that's cross-repo *within that
  domain* — e.g. any GAS/clasp project benefits from `gas-apps-script.md`, but a
  project with no GAS in it gains nothing from reading it inline in `AGENTS.md`.
- `CLAUDE.md` (global or per-repo): stays mostly pointers back to `AGENTS.md`/
  `~/.knowledge/` and to each repo's own docs, plus whatever is genuinely specific to
  Claude Code itself (its tool/slash-command conventions, and policy for how Claude
  drives *other* agents — subagents, multi-agent workflows). Not a parallel copy of
  general knowledge that belongs in one of the tiers above. If content would be
  useful to a different agent/tool reading the same repo, it doesn't belong in
  `CLAUDE.md`.
- `~/.codex/AGENTS.md`: Codex CLI's own global rules file — Codex has no `@file`
  import mechanism and doesn't recognize `~/AGENTS.md` as a location at all, so
  whichever of the universal principles above are meant to bind Codex too have to be
  hand-duplicated there (see `setup/ai-agent-config/` in the mactl repo for the
  mechanics). It otherwise carries persona/style rules that are specific to Codex and
  don't belong here.

### 2026-09-02 — Work out how cost scales with N before dispatching a parallelization/architecture change

When proposing or approving an implementation that touches performance or scaling
(parallelization, sharding, batching, caching), write out algebraically how each
participant's cost scales with the relevant size parameter(s) *before* dispatching
the implementation — specifically check for a straggler/worst-case actor whose cost
grows with its position or index instead of staying `O(N/W)`. A small-scale test
passing is not a substitute for this: it can look like a real win while hiding an
asymptotic problem that only bites at the actual target scale.

Concrete case: parallelizing a video-frame-capture pipeline across W workers by
contiguous frame ranges, where correctness required each worker to replay all prior
frames from 0 before starting its own range (to rebuild a piece of animation state
that only holds if built up frame-by-frame). The last worker's replay cost is
`(W-1)/W` of the *entire* original sequential job — fully predictable on paper, no
test needed — yet it only surfaced after implementing and testing at a small frame
count, where the effect was still small enough to look like a real (if modest) win.
The scale-invariant fix (every worker walks the full range but only captures its own
slice) has a cost ratio that stays constant regardless of N; verify that kind of
claim the same way, by reasoning about the ratio's behavior as N grows, not by
retesting at one more arbitrary N and hoping it generalizes.

## Domain-specific knowledge index

- **Google Apps Script / clasp**: see [`~/.knowledge/gas-apps-script.md`](./.knowledge/gas-apps-script.md)
  (esbuild-bundled simple-trigger gotcha, `clasp run` permission/OAuth-scope setup).
