# CLI adapters

Office Room 1.1 discovers CLI executables from the backend's PATH. Claude Code and Codex have built-in transports. Other recognized names are shown as unsupported until a compatible adapter is configured. Installed, authenticated, catalog available and user-enabled are separate states. The native app uses the same registry for cards, settings and the 3D office.

Models and reasoning efforts come from Claude's stream-json initialization metadata and Codex app-server `model/list`, including pagination. A catalog is not proof that every model is permitted for the account. Failures are shown to the user; the router never silently substitutes a brand/model/effort.

## Adding another CLI

Install a local wrapper that implements the following `office-jsonl` contract, then use Settings → AI ในเครื่อง → เพิ่มตัวเชื่อม CLI. Enter a unique ID and an absolute executable path. The app executes argument arrays, never a shell command assembled from the path. Do not point this at an ordinary CLI that lacks the contract.

The adapter is trusted installed code. Office Room does not download or generate executable adapters automatically. It must translate the target CLI's login, streaming, session resume, cancellation and permission behavior. Unsupported permissions keep the adapter out of the corresponding workflow.

`wrapper --version` prints a version and exits. `wrapper --office-capabilities` writes one JSON line and exits. Example metadata (illustrative, not a real provider):

```json
{"type":"capabilities","authState":"loggedIn","permissions":{"readOnly":true,"workspaceWrite":true},"models":[{"id":"example-model","displayName":"Example","description":"Description from the CLI","isDefault":true,"defaultEffort":"low","supportedEfforts":["low","high"]}]}
```

Optional `quotaGroup` identifies adapters known to share one quota. When an account/CLI limit is reported, all registered adapters in that group rest together. Omit it when the scope is unknown. Model metadata may omit effort support: the application does not invent effort levels, and permits an omitted override only if user policy allows runtime defaults.

`wrapper --office-run` receives one JSON line on stdin:

```json
{"type":"run","role":"worker","prompt":"room context","instructions":"team rules","model":"example-model","effort":"low","mode":"read","writableRoots":[],"sessionId":null,"images":[]}
```

For `role: "coordinator"`, the wrapper receives `prompt`, `model`, optional `effort`, `mode: "read"`, and `tools: []`. It must disable tools and return only the requested selection decision inside a result event. The coordinator's decision includes `lead`, `model`, `effort`, `assignment`, `reason`, `summary`, `first_step`. The server validates it against current capability and policy.

Worker stdout accepts these events (each a JSON line):

```json
{"type":"step","text":"current progress"}
{"type":"agent","id":"child-id","status":"running","label":"Check API contract"}
{"type":"agent","id":"child-id","status":"completed"}
{"type":"limit","resetsAt":1800000000000}
{"type":"result","text":"final answer and routing footer","sessionId":"opaque-session-id","tokens":100}
```

On failure, emit a result with `error` and exit nonzero. After a limit event, exit without accepting new work. SIGTERM must stop all child work. The wrapper must reject WRITE when permissions are unsupported and resume only sessions belonging to this assignment. Image entries are local attachments, not instructions to execute.

Only the worker's final result may carry a routing footer:

```text
[[NEXT {"to":"member-id","model":"catalog-selector","effort":"high","mode":"read","assignment":"distinct deliverable","reason":"why this member/model/effort"}]]
[[NEXT {"to":"user","kind":"approve","then":"member-id","model":"catalog-selector","effort":"high"}]]
[[NEXT {"to":"done"}]]
```

Legacy key/value footers remain readable. Routing markers from intermediate tools/progress are not decisions. IDs and model selectors preserve case.

## Task completion and delivery

Workers receive the current assignment, approved plan, change revision and recovery checkpoint in every turn, including already-loaded Codex threads. The delivery cursor advances only through the prompt batch, so user messages arriving during a turn are processed before closing the task. Successful Codex steer is recorded per message; rejected steer stays queued. Attachments are acknowledged only for the batch actually sent.

The full approved plan is sent on first delivery to each member or whenever it changes; subsequent turns reference its hash, plan-message ID and the room file/field containing the plan, so it can be read again after context compaction. A new session receives the full plan again. Recovery checkpoints are consumed by the next successful worker turn rather than repeated indefinitely. A usage-limit takeover after a partial WRITE starts READ to inspect effects before routing back to approved WRITE.

Approval belongs to the current task and its displayed plan. Completion or user cancellation expires it; a new task in the same room starts READ and takes a new diff baseline when approved. Unfinished legacy approvals remain valid for that task. Any WRITE attempt invalidates the earlier review, including partial failures. Failed WRITE is not replayed automatically; manual retry starts READ with a partial-effects checkpoint.

`to: "done"` now requires a compact `completion` object in the final routing JSON:

```json
{"to":"done","completion":{"summary":"What was completed","checks":[{"name":"Relevant check","result":"passed","evidence":"Actual file, command or observed result","required":true}],"remaining":[]}}
```

`result` is `passed`, `failed` or `not_run`. Required failures, unrun required checks, remaining work, or WRITE work without a passed required check keep the task waiting for verification. Optional/out-of-scope checks may use `required:false` with a reason. These are explicitly **worker-reported** results, not independent proof that the server executed a test. Missing reports receive one READ correction turn, then pause; existing valid checks should be reused.

After nontrivial WRITE work, an independent READ reviewer supplies `review:{"revision":1,"status":"passed","evidence":"What was inspected"}` in its routing JSON. Only a different member's review of the current revision is accepted. A review can also report `changes_requested`. Trivial work may include `completion.review:{"status":"not_required","reason":"Why trivial"}`. `self_reviewed` needs a reason and is accepted only when no independent member is ready. This classification is reported by the worker and remains visible to the user. Review readiness and reported evidence do not establish model-output quality.

## Permissions and existing data

Claude READ exposes only Read/Glob/Grep, disables local customizations/MCP, and also runs under a macOS filesystem sandbox denying writes to every selected project. Approved WRITE enables working tools inside selected project roots, with temporary/CLI bookkeeping paths and git metadata protection. Third-party wrappers use the same filesystem boundary and must advertise their own permission support. Codex uses app-server readOnly/workspaceWrite sandbox policies. Permission prompts cannot bypass the room's approval state. Skills in READ may be read as files; code-executing skill actions need an approved WRITE turn.

Settings schema 2 keeps existing model allow-lists, effort ceilings, budgets and unrelated fields. Old brand-routing defaults are retained in `legacyRouting`, while automatic coordination uses live candidates. On the first settings write, the old settings file is copied to `settings.json.pre-v2-<timestamp>.bak`. Rooms retain their existing CLI session keys; the reader adds state without rewriting every historical room. `data/catalog.json` is a metadata cache with observation times; unknown auth is rechecked rather than inferred from cache.

The first coordinator is sampled without a provider priority among CLIs whose runtime defaults satisfy user policy, or uses an explicit coordinator override from Settings. It then selects the actual work assignment. If an old effort ceiling cannot be proven compatible with a runtime default, set an explicit coordinator model/effort or adjust the ceiling in Settings. A missing/invalid decision pauses for correction; it never picks the first brand in an array.

`maxAutoTurns: 0` allows reasoning-driven completion. Existing nonzero values remain an explicit visible budget until changed in Settings; reaching one asks to continue and does not claim the task is complete.

Rollback: keep the previous app/source and restore the settings backup before starting the previous backend. The new catalog cache can be ignored by the previous version. Do not restart either version while rooms are running.

## Verification

Run `sh tests/run.sh`. It uses isolated temporary data and stub CLIs, including three `office-jsonl` adapters, READ denial / approved WRITE, limit takeover/exhaustion, cancellation, strict capability validation, native N-agent layout, chat history/streaming and clipboard behavior. It does not run paid model inference. Real CLI metadata checks and screenshots from this change are recorded under `.handoff/implementation/` locally.

## macOS team workflow

The local HTTP service is the macOS app backend. New rooms have `workflow` state; legacy unfinished rooms retain their prior lifecycle. New/reused tasks start a READ meeting. Every available member contributes before the room accepts a plan. Missing facts go to the human; no timer/default supplies a decision.

A plan request uses this routing payload (plus the ordinary displayed prose):

```json
{"to":"user","kind":"approve","teamPlan":{"summary":"Confirmed scope and acceptance","flow":"flowchart TD\n A[Brief] --> B[Work]","tasks":[{"id":"api","owner":"member-id","model":"allowed-selector","effort":"allowed-effort","assignment":"Distinct deliverable","reason":"Why this member/model/effort","files":["/absolute/project/file"],"dependsOn":[]}]}}
```

The backend validates owners, model policy, project boundaries and dependency cycles. The displayed approval includes the exact task scopes and Mermaid source. After approval, Markdown/Mermaid artifacts are created under `.office-workflow/<room-id>/` in the first project. Artifact filenames include the plan identifier to preserve previous decisions. `GET /api/rooms/:roomId/documents/:documentId` reads only registered artifacts and rejects symlink traversal. The native app currently shows Mermaid source, explicitly labelled as source.

Tasks execute in separate temporary project copies (no git metadata); an owner has one active task and overlapping paths wait. Claims are absolute original project paths, mapped into each isolated working directory. Integration accepts only scoped regular-file changes, compares source hashes/modes to catch intervening human changes, rejects symlink writes, and prevalidates the full change set. An I/O failure rolls back applied file changes. `.office-task-tmp/` is reserved for test/build output and excluded from integration. The working copy is retained on failure for READ inspection; failed WRITE is never automatically replayed. Manual retry obtains an independent READ inspection before continuing the partial copy.

Independent tasks continue while another task waits for the human. Each integrated task receives an independent READ review; overlapping later writes invalidate affected earlier task reviews. Combined checks run in a fresh copy of the integrated project, and a fresh source comparison rejects edits made during testing. Delivery requires task reviews and reported required integration checks to pass. These are attributed agent reports, not independent proof of model output quality. Loop budgets count task/review/check calls as well as ordinary turns.

`workflow.phase`: `meeting`, `planning`, `working`, `review`, `testing`, `delivered`. `workflow.tasks[]` includes id/owner/assignment/files/dependsOn/status/revision/live plus `reviewer` while reviewing. `workflow.verification` supplies owner/status/live for combined checks. A task's author stays in `owner` when another member reviews it.

Structured questions are sent in the room routing footer:

```json
{"to":"user","kind":"ask","questions":[{"id":"target","question":"Where should it run?","options":[{"label":"macOS","description":"Local app"},{"label":"Web","description":"Browser"}],"multiSelect":false}]}
```

Native Codex `item/tool/requestUserInput` / `tool/requestUserInput` server requests use the same UI state. All permission requests remain denied by the room; asking a question grants no extra filesystem/network access. Claude's noninteractive READ tool set stays read-only; it uses the shared routing format for user questions instead of requiring an interactive terminal.

`room.questions[]` holds outer id/from/status/source/taskId and an inner questions array of id/header/question/options/multiSelect. The host assigns stable option ids. `POST /api/rooms/:roomId/answer` takes `{questionId,answers:{<innerId>:{selected:[<optionId>],text:""}}}`. Every question requires a selection or custom text. Identical retries are idempotent; conflicting retries and expired questions fail. A closed sheet retains its local draft; closing it does not answer or cancel work. Pending native Codex requests expire on turn interruption or server restart, with no invented answer.
