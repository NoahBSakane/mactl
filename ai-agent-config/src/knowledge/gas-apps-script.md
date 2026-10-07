# Google Apps Script / clasp — cross-project notes

Domain-specific lessons for anyone (any AI agent/tool) working on a Google Apps
Script project managed via `clasp` (esbuild-bundled TypeScript, `clasp push`/`clasp
run`, etc.) — not just one repo's. Linked from `~/AGENTS.md`'s index rather than
inlined there, since it's irrelevant to projects that aren't GAS/clasp-based.

## 2026-08-07 — Google Apps Script + esbuild bundling: simple triggers need a literal `function` declaration

If a GAS project is built by bundling TypeScript/JS into an IIFE (e.g. via esbuild)
and exposing GAS-callable functions only via `Object.assign(globalThis, {...})`, this
works fine for:

- menu item handlers (looked up dynamically by name string when clicked)
- installable/time-driven trigger targets (looked up dynamically by name when the
  trigger fires)

It does **NOT** work for GAS's "simple triggers" (`onOpen`, `onInstall`, `onEdit`,
`doGet`, `doPost`): GAS appears to detect these by statically scanning the deployed
source for a literal top-level `function onOpen() {...}`-style declaration, not by
checking the global object at runtime. If only a dynamic assignment exists, the
trigger silently never fires — no error, no log entry anywhere (not even in Cloud
Logging). A custom menu built in `onOpen`, for example, will simply never appear, with
zero trace of why.

**Fix**: always keep a small literal-function-declaration shim for these specific
reserved names in the build output, e.g.:

```js
function onOpen(e) { return globalThis.__MYAPP__.onOpen(e); }
function onInstall(e) { return globalThis.__MYAPP__.onInstall(e); }
```

even if every other exported function can safely rely on dynamic
`Object.assign(globalThis, {...})`.

**How this was found**: incident in a client-project repo — see that
repo's `CLAUDE.md` "Known Gotchas" section for the full writeup. Diagnosed via GCP
Cloud Logging:

```bash
gcloud logging read 'resource.type="app_script_function"' --project=<GAS-linked GCP project id> --limit=30 --format=json
```

The linked GCP project ID/number for a given Apps Script project is under the script
editor's Project Settings ("Google Cloud Platform (GCP) Project" section) — it must be
a Standard (user-managed) project, not the default auto-created one, for `gcloud
logging`/Cloud Console to have access to it at all.

The diagnostic signal was the *absence* of any log entry at all for the broken
trigger, versus a clear, stack-trace-bearing entry for an unrelated real failure
(a Gmail authorization error) that happened around the same time on the same project.
Absence of logging = GAS never attempted to invoke the function; a thrown error always
gets logged when `exceptionLogging: "STACKDRIVER"` is set in `appsscript.json`.

## 2026-08-19 — `clasp run` needs more than "enable the Apps Script API + consent once in the editor"

Symptom: `clasp run <function>` returns `Unable to run script function. Please make
sure you have permission to run the script function.` — this persists even after:

- enabling "Google Apps Script API" in the account's script.google.com/home/usersettings
- adding `"executionApi": {"access": "MYSELF"}` to `appsscript.json`
- a human manually running a function once in the Apps Script IDE and clicking
  through the OAuth consent screen for the project's actual scopes (BigQuery, Drive,
  Sheets, Slides, external requests, etc.) — this only proves the *script* is
  authorized for that *user*, not that the separate token `clasp run` presents is
  valid

Two distinct, non-obvious gates are actually involved:

**Gate 1 — the default clasp OAuth client gets blocked outright.** `clasp login`'s
default OAuth client only carries clasp's own fixed scope set
(`script.deployments`/`script.projects`/`drive.file`/etc.). It does not include
whatever scopes the target script project's actual code needs (BigQuery,
`spreadsheets`, `presentations`, full `drive` for accessing a pre-existing folder by
ID, `script.external_request` for `UrlFetchApp`, `script.scriptapp` for trigger
management, etc). Trying to grant those broader/sensitive scopes to clasp's shared
default client trips Google's "this app is blocked" screen — the client isn't
verified for them, and some Workspace orgs restrict unverified apps from sensitive
scopes entirely.

**Fix**: create your own OAuth client (Desktop app type) in a GCP project under your
Workspace org, with the OAuth consent screen's **User Type set to Internal** (only
selectable for org-owned projects; internal apps skip Google's verification/blocking
requirement entirely for users in the same domain). Then re-login with it:

```sh
npx clasp login --creds <path-to-downloaded-client-secret.json> --use-project-scopes --include-clasp-scopes
```

Run this from inside the directory that has the target `.clasp.json` (clasp reads the
local `appsscript.json` to compute the scope union with `--use-project-scopes`). With
a Desktop-app credential this completes via a local-server redirect automatically (no
manual URL paste needed) once you finish the browser consent screen.

**Gate 2 — the OAuth client's own GCP project needs the Apps Script API enabled.**
Even after Gate 1 succeeds (correct scopes, no blocking), `clasp run` can still fail
with the exact same "permission to run the script function" message. This is *not* a
scope or consent problem — it's that `script.googleapis.com` (Apps Script API) hasn't
been enabled as a *service* on the GCP project tied to the OAuth client used for the
call (separate from BigQuery/Drive/Sheets/Slides APIs, easy to overlook, and Google's
generic error message doesn't distinguish this from Gate 1):

```sh
gcloud services enable script.googleapis.com --project=<oauth-client's-gcp-project-id>
```

Once enabled, the *same already-issued token* starts working immediately — no
re-login needed. This is the tell that Gate 1 was already fine and Gate 2 was the
remaining blocker.

**Bonus gotcha**: `clasp run` prints `No response.` when the invoked function returns
`void`/`undefined` — this is not a failure, just an empty result. Check `clasp logs`
for the actual execution output (requires `"projectId": "<gcp-project-id-string>"` in
`.clasp.json`, which is not part of what `clasp create`/`clasp clone` write by
default).

**Where this was found**: a multi-app reporting repo's `apps/app-a` — see that repo's
README.md ("clasp run で自己検証する場合のセットアップ") for the project-specific
setup (GCP project number, credential storage location, etc).

**Gate 0 (check this first, before Gate 1/2 above) — the OAuth client and the target
script must share the *same* GCP project.** If `clasp run <function>` fails with the
exact same generic `Unable to run script function. Please make sure you have
permission to run the script function.` message even though Gate 1 and Gate 2 are
both already satisfied *for a different project's client*, the actual cause can simply
be: you're currently logged in with an OAuth client that belongs to GAS project A's
GCP project, and trying to run a function on GAS project B (a completely separate GCP
project) with it. This is a hard requirement, confirmed in Google's own docs
([Enable script authorization and
access](https://developers.google.com/apps-script/api/how-tos/enable)): "the script
and calling application's OAuth2 client must share a common Google Cloud project" —
explicitly linking the script's manifest to project B's GCP project number (Gate 0's
sibling requirement, the "GCP Project" field under the script editor's Project
Settings) is *not* sufficient on its own if the token you're presenting was issued for
project A's client.

**Fix**: there is no way to make one OAuth client work across multiple GAS
projects that live in different GCP projects — create a separate custom OAuth client
per GCP project (same Gate 1 recipe: Desktop app type, User Type Internal, in that
specific project), then switch which one is active by re-running `clasp login
--creds <that-project's-client-secret.json> --use-project-scopes --include-clasp-scopes`
from inside the directory with the target `.clasp.json` before each `clasp run`
against that project. `~/.clasprc.json` only holds one active token at a time (see the
"juggling multiple OAuth clients" lesson below), so this is a real per-session
switching cost, not a one-time setup step.

**Diagnostic tell**: if a sibling GAS project *does* work with the currently active
client (e.g. project A runs fine, project B doesn't, both otherwise configured
identically — same manifest shape, same "Apps Script API enabled" status, same
explicit GCP project link done), suspect Gate 0 before re-checking Gate 1/2 again —
re-verifying scopes/consent/API-enablement on project B won't surface anything new if
the real issue is simply "wrong client for this project."

**Where this was found**: a multi-app reporting repo — `apps/app-b`'s `clasp run` worked
(its own dedicated OAuth client, in its own `app-b-reporting` GCP project), but
`apps/app-c`/`apps/app-d` failed with the generic permission error even after
confirming their Apps Script API was enabled and their scripts were explicitly linked
to their own (`app-c-reporting`/`app-d-reporting`) GCP projects. Both
were resolved only after creating a dedicated OAuth client per project and switching
to it before running.

## 2026-08-19 — duplicated fetches in a multi-report GAS pipeline are what burn the daily API quota

Symptom: a previously-working `clasp run <function>` starts failing with
`Exception: Service invoked too many times for one day: premium urlfetch.` —
this is Google's daily quota for `UrlFetchApp` (which GA4 Data API calls and
JWT token exchanges route through; BigQuery Advanced Service calls have
their own separate daily quota too), and it resets roughly once every 24
hours. No amount of retrying fixes it same-day; the fix is to wait.

The first instinct is "I ran `clasp run` too many times while debugging" —
and that's a real contributor, but check for a bigger and more permanent
cause first: **does the pipeline itself call the same fetch, with the same
arguments, more than once per run?** A monthly/weekly report generator that
internally builds several independent sub-reports for the same target
period (e.g. a "numeric" + "insight" + "pickup" + "slides" report, each
built by its own top-level function) is a classic place for this — if each
sub-report's function independently fetches the *same* BigQuery tables and
the *same* GA4 report definitions for the *same* period, a single pipeline
run can multiply what should be one fetch into 3-4x as many. This isn't
just a testing inconvenience: it means the real, scheduled production
trigger burns the same multiplied quota every single time it fires, and
compounds with any same-day manual re-runs or backfills.

**Fix (do this first, it's the actual production fix, not just a testing
convenience)**: have the orchestrating function fetch each distinct piece of
data *once*, then pass the bundle down to every sub-report generator as an
optional parameter that each generator falls back to self-fetching only
when called standalone (so narrow single-report debugging/testing is
unaffected and still works without the bundle). Look for this any time a
pipeline has more than one function that independently calls the same
fetch/report-building helper for what is conceptually the same input data —
it's easy to miss because each sub-report's own code looks self-contained
and correct in isolation.

**Fix (secondary, testing-only convenience)**: once the pipeline is properly
deduplicated, also expose each independent sub-step as its own
separately-callable entry point (e.g. `generate<X>ReportOnly(year, month)`
alongside the full-pipeline entry point), so a narrow fix can be verified by
calling just the affected sub-step — still worth doing since even a
deduplicated pipeline's *full* run costs more than testing one piece of it.

**Where this was found**: a multi-app reporting repo's `apps/app-a` — the monthly
report pipeline builds 5 sub-reports (numeric/insight/pickup/merged/slides);
3 of them (numeric/insight/slides) each independently called
`fetchAllAppABigQueryData_` (18 BigQuery tables) and the same 4 GA4 report
calls for the identical target month — roughly 4x the necessary BigQuery
calls and 3x the necessary GA4 calls per pipeline run, in both testing and
real monthly production use. Repeated full-pipeline test runs on top of
that exhausted the day's quota before a bug-fix batch could be verified
live. As a bonus, deduplicating the fetch also eliminated a separate
correctness risk: the insight report and the slide deck computing their
"same" numbers from independently-timed fetches could in principle disagree
for the same month; sharing one fetch guarantees they can't.

## 2026-08-31 — before a `clasp run` live check, read `clasp logs` for *today's* executions first

Symptom: ran a single, deliberately-minimal `clasp run <function>` for
verification, and it *still* hit `Service invoked too many times for one
day: premium urlfetch` — with no obvious excessive-retry explanation this
time.

Root cause found via `clasp logs` (requires `.clasp.json`'s `projectId`,
same as above): a **production time-driven trigger had already fired earlier
that same day** against the *same* target period the verification run was
about to re-request (e.g. a weekly trigger that ran at 07:xx already
generated that week's report; a manual verification run at 14:xx for the
identical week then pushed the day's combined quota usage over the edge).
The verification run itself wasn't "too many retries" — it was one
legitimate run stacked on top of a production run that had already consumed
a meaningful chunk of the shared daily quota.

**`premium urlfetch` is a per-Google-user-account quota, not a per-GCP-project
one.** Google's own Apps Script quota reference states URL Fetch calls are
metered "per user, per day" (20,000/day for a consumer account, 100,000/day
for Google Workspace) — every GAS project owned by the same Google account
draws against one shared daily budget, regardless of which GCP project each
script is linked to.

**Fix — make this the very first step before *any* `clasp run` live
verification, not an afterthought**: check `clasp logs` for *every* GAS
project owned by the same Google account (not just the target project)
before verifying, and scan for:

1. any execution (trigger-fired or manual, yours or someone else's/another
   session's) already logged *today* on *any* of that account's projects,
   especially one covering the *same* target date range/month you're about
   to re-verify — if found, treat that as "today's account-wide quota budget
   is already partially spent," and lean toward deferring the verification
   to tomorrow rather than proceeding
2. any prior `premium urlfetch` quota-exceeded error already logged today on
   *any* of that account's projects — if present, the quota is very likely
   still exhausted account-wide regardless of what you're about to run;
   don't retry same-day

Reset timing is "~24h after the first request that day," not a fixed
wall-clock time, so don't assume a specific reset hour.

**Where this was found**: a multi-app reporting repo, verifying an
uncommitted GA4-batching refactor across `apps/app-a` and `apps/app-b` on
the same day — `apps/app-b`'s own weekly production trigger had already run
successfully that morning for the exact week being re-verified in the
afternoon; the stacked manual run is what tipped it over. `apps/app-a` hit
the same error from a single fresh run, consistent with the "01. multi-report
pipeline duplicates fetches" lesson above compounding on whatever quota the
day's earlier activity (this project's or another session's) had already
used.

## 2026-08-31 — juggling `clasp run` across multiple GAS projects on one machine means juggling multiple OAuth clients too

If more than one GAS project on the same machine has its own dedicated
custom OAuth client set up for `clasp run` (see the "Gate 1" lesson above —
e.g. one project's client for `apps/app-a`, a separate one for a different
`apps/<client>`), `clasp login`'s credential store (`~/.clasprc.json`) only
holds **one active token at a time**. Logging in with project B's
credentials silently displaces project A's — the next `clasp run` against
project A then fails with the exact same generic `Unable to run script
function` message as an unrelated permissions problem, which is easy to
misdiagnose as "the setup broke" rather than "a different project's
credentials are just active right now."

**Fix**: keep every project's downloaded OAuth client-secret JSON
(`type: installed`) around locally (e.g. a repo's own git-ignored
`credentials/` directory, one file per project/client, named after the
project) instead of treating the one-time `clasp login --creds` as a
throwaway step. Switching which project you can `clasp run` against is then
just re-running:

```sh
npx clasp login --creds <path-to-that-project's-client-secret.json> --use-project-scopes --include-clasp-scopes
```

from inside that project's own directory. Document *why* each file exists
(which GCP project/client it belongs to, which `apps/<client>` it's for) in
a README next to them — the files themselves carry no obvious label once
there's more than one, and re-downloading a lost one means going back to the
GCP Console's Credentials page for that specific project rather than being
able to recreate it from anything in the repo.

**Update (2026-09-25) — named credentials remove the switching cost entirely.**
The "one active token at a time" premise above only holds for the *default*
credential. clasp v3 has a global `-u, --user <name>` option that stores
**named** credentials side by side in `~/.clasprc.json`. Log in once per
project from inside its directory:

```sh
npx clasp login --user <app> --creds <that-project's-client-secret.json> --use-project-scopes --include-clasp-scopes
```

and from then on target it with `clasp run --user <app> <function>` /
`clasp logs --user <app>` — no re-login when switching between projects.
Verified in a multi-app reporting repo with eight named users (one per `apps/<client>`) coexisting.

Two more things surfaced while doing this:

- A downloaded client-secret JSON can go stale without warning: if the OAuth
  client was deleted in the GCP Console, the browser consent screen fails with
  `Error 401: deleted_client`. The only fix is creating a new Desktop client in
  that project and logging in with the new JSON.
- Gate 0 (script and client must share a GCP project) can be broken on the
  *script* side even when the repo's `.clasp.json` `projectId` looks right —
  `.clasp.json` doesn't control the link. Check the script editor's Project
  Settings → GCP project number; re-pointing it there fixed an otherwise
  identical setup that kept returning the generic permission error.

## Don't add `LockService` on your own: propose it, and use it only once approved

`LockService.getScriptLock()`/`waitLock()`/`releaseLock()` only ever
mutually-excludes *within the same script project's own executions* — it
does nothing for concurrent writes from a *different* GAS project (there is
no cross-project lock primitive). If a design already tolerates
cross-project races on some shared resource (e.g. multiple independent GAS
projects all writing counters to one shared spreadsheet), bolting a
same-project-only lock onto just one of the writers is inconsistent
complexity that doesn't actually close the race — it only adds a new
failure mode (`waitLock` can itself throw on timeout) for a guarantee that
was already given up on elsewhere. Default to no locking; a rare lost
increment/overwrite on a low-frequency, best-effort counter is usually a
smaller cost than the added code complexity.

When a lock does look warranted (a same-project race that has actually been
observed, or a design that clearly needs one), do not add it unprompted:
*propose* it to the user (via the question UI), saying which race it closes,
what it cannot close (other projects), and the new failure mode. Add it only
after the user approves, and then follow the next section. An explicit
instruction from the user to add a lock counts as approval.

## 2026-09-29 — design failure paths to self-heal on the next scheduled run

When a GAS automation exists to save human effort, a failure that is only
*visible in the log* still costs a human to fix it. When designing anything
that can fail, first design the path by which the next scheduled run (e.g. a
per-minute trigger) retries or repairs it automatically; keep the log as an
aid for tracing what happened. Also check that the code that records the
failure (a retry queue, a marker row) cannot fail for the same reason as the
original operation (the same lock, the same quota). Example: if deleting a
candidate row fails, the next confirmation run that receives
`message_not_found` from `reactions.get` deletes the row again.

## 2026-09-29 — once a lock is approved: inventory every use, keep the hold minimal

(Follows "Don't add `LockService` on your own" above: this is how to do it
once a lock has been approved.) When a project shares one `ScriptLock` across
all processing, some paths give up (`tryLock(0)`, "skip this round") while
others wait (`waitLock(30s)`) and then fail. Wrapping a whole long-running
function in the lock (one that waits minutes on a Slack rate limit) lets a
concurrent, more important process fail: a helper's safety net must not stop
the main function. Before touching a lock: `grep LockService`, tabulate every
use and what happens when the lock cannot be taken; hold it only around the
shared-data operation (seconds of sheet access), never across external API
calls or `sleep`; do not re-acquire from a caller that already holds it (pass
a `lockHeld` flag).

## 2026-10-07 — bulk-reading Gmail/Sheets from a local script: go sequential, wait on 429, keep what succeeded

When a local script (OAuth token on the machine, not the GAS runtime) reads
hundreds of Gmail messages or many Sheets ranges, the per-user per-minute
quotas are the limit, not the daily ones. Fetching 700 messages with 5 workers
failed 554 of them with "Quota exceeded for quota metric 'Total Query Cost'"
(Gmail), and chaining a few small Sheets read scripts hit the 60 reads/minute/user
limit (HTTP 429).

- Run sequentially (concurrency 1) with a short pause between calls.
- On 429 / quota errors, wait (about 20 s) and retry the same item; give up
  after a handful of attempts.
- Persist what succeeded (a cache file) and fetch only the failures on the next
  run, so a re-run never re-reads everything.
- Keep the cache outside the repository and delete it afterwards if it holds
  mail bodies.
