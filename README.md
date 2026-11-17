# agent-pipeline

A Claude Code plugin that takes a one-line feature request to a mergeable pull request, using a team of specialized subagents:

```
detect-stack → planner → property-finder → advocates ×N ∥ → judge → test-writer (red + held-out) → implementer (green) → held-out check
               (opus)    (sonnet)          (sonnet)         (opus)  (opus)                         (sonnet)

  → mutator → evaluator (running system) → reviewer ⟲ → PR → land ⟲ (CI, review bots, conflicts) → mergeable
    (sonnet)  (opus)                       (opus)
                                           ∥ security-reviewer (opus, security-sensitive changes)
```

- **Works on any repo.** `detect-stack` reads manifests, CI config and docs to find the real test, lint and typecheck commands, and writes them to `.claude/pipeline/config.json`. That folder is git-excluded, so the repo stays untouched.
- **Debate, not one opinion.** One advocate per design option argues from the code, in parallel. A judge checks their claims and writes an ADR.
- **Tests-first with a different model.** The test-writer encodes the acceptance criteria as failing tests, which get their own commit. The implementer runs on a different model and has to make them pass.
- **Enforced, not requested.** A `PreToolUse` hook blocks the implementer from editing any test file. If it thinks a test is wrong, it has to stop and say why.
- **Held-out tests.** Some acceptance tests are kept back from the implementer and run only after it's done, so an implementation shaped to the visible tests shows up. See [Held-out tests](#held-out-tests).
- **Checks can't be switched off.** A hook stops the implementer and mutator from adding `eslint-disable`, `@ts-expect-error`, `# noqa`, coverage ignores and the like, or from editing lint, typecheck, test, coverage, hook or CI config. A diff scan catches the same changes made any other way.
- **Properties, not just examples.** The planner and a blind second agent list what must *always* hold (round-trips, nothing lost, rejected means no effect, …), and the test-writer encodes those as property-based tests.
- **Tests that can fail.** After green, a mutator breaks the code once per criterion and property and checks that a test catches it.
- **The running system, not just the tests.** An `evaluator` starts the app and checks each acceptance criterion through its real interface (HTTP, CLI, browser), plus the flows next to it.
- **Independent review, with verified findings** by a model that didn't write the code. Each finding is reproduced as a failing test (or checked against the cited line) before it's fixed; findings that can't be confirmed are listed, not acted on. Every confirmed finding except a cosmetic nit gets fixed, not just the must-fixes.
- **Security-sensitive changes get more.** The planner tags changes to auth, crypto, secrets, money, identity verification or permissions. Those runs add hostile-input properties, a red-team `security-reviewer`, and stricter review. See [Security-sensitive changes](#security-sensitive-changes).
- **No bypassed checks.** A second hook stops pipeline runs from skipping git hooks (`--no-verify`, `core.hooksPath`, `HUSKY=0`, …). If a hook fails, the pipeline fixes the cause.
- **Only the planned change ships.** Preflight warns if the branch already carries commits, and before the PR the pipeline checks the diff against the plan's affected files.
- **Ships a PR in the repo's own format.** The body follows the repo's PR template, the commits follow its commit convention, and the repo's written PR rules are checked; the plan, ADR and traceability tables go in a pipeline report at the end.
- **Lands it.** After opening the PR, the pipeline watches CI, fixes failures the branch caused, re-runs flakes once, merges the target branch in on conflicts, and answers review bots, until the PR is mergeable. It never merges, approves or resolves a person's thread. See [Landing the PR](#landing-the-pr).
- **Resumable, and stops when it stops improving.** Run state is saved after every stage, so `--resume` continues a run after a crash or a closed session. Every fix loop stops early when a round doesn't reduce what's failing.

## Install

One command, from any directory:

```bash
claude plugin install agent-pipeline --marketplace doug-patterson/agent-pipeline
```

Or, inside Claude Code:

```
/plugin marketplace add doug-patterson/agent-pipeline
/plugin install agent-pipeline@agent-pipeline
```

## Use

From the root of any git repo, in Claude Code:

```
/agent-pipeline:pipeline add rate limiting to the /orders endpoint
```

### Flags

Put flags anywhere in the request. Combine them freely.

| Flag | What it does | Use it when |
|---|---|---|
| `--spec <source>` | Grounds the run in a requirements source: a local file (PRD, design doc, exported ticket; PDF and DOCX are converted), a URL, or a Linear issue ID or URL. Repeat it for several sources. The request text can then be empty. See [Working from a PRD or Linear issue](#working-from-a-prd-or-linear-issue). | The work comes from a ticket or PRD. Prefer this to pasting the text into chat, because subagents never see the conversation. |
| `--fast` | Skips the design debate (advocates and judge) and uses the planner's recommended option. Also skips the blind `property-finder`, except for security-sensitive changes; the planner's own property pass and the mutation check still run. | The design is obvious, or the change is small. |
| `--auto` | Never stops for you. Doesn't confirm the plan's assumptions (properties that need a product decision become open gaps instead of tests); runs in a new worktree if your checkout has uncommitted changes; has the judge rule on disputed tests; keeps prior commits and reverts its own out-of-plan edits. Anything it couldn't settle goes under "Needs a human" at the top of the PR. | You trust the request as written, or you're running unattended. |
| `--no-properties` | Skips property discovery, property tests, the mutation check and the `INVARIANTS.md` update. Existing invariants are still read and reviewed against. | Wording, styling or config changes with no logic. (The planner also exempts these on its own.) |
| `--no-eval` | Skips exercising the running system. | The app can't run locally, or the change has no runtime surface. (Libraries skip it on their own.) |
| `--base <branch>` | Starts the run from the tip of `<branch>` and opens the PR against it, instead of the default branch. The branch must already exist; to open a PR it must be on the remote. | Targeting a release branch, or stacking on another feature branch. |
| `--draft` | Pushes the branch and opens the PR as a draft. Without it, the PR is opened ready for review. | You want CI to run and teammates to see the work before it asks for review. |
| `--no-pr` | Stops at a committed local branch and prints the PR description. Nothing is pushed. Takes precedence over `--draft`, and implies `--no-land`. | You want to look before anything leaves your machine. |
| `--no-land` | Stops once the PR is open, without watching CI or answering review bots. | You'd rather drive the PR yourself, or the repo has another bot doing it. |
| `--resume [slug]` | Continues an unfinished run from its last completed stage. With one unfinished run, the slug is optional. | The session crashed, compacted badly or was closed mid-run. |

Examples:

```
/agent-pipeline:pipeline --fast fix the off-by-one in pagination on /orders
/agent-pipeline:pipeline --spec ENG-123 --no-pr
/agent-pipeline:pipeline --spec ENG-123 --draft
/agent-pipeline:pipeline --base release/2.4 backport the /orders rate-limit fix
/agent-pipeline:pipeline --auto --no-properties update the footer copyright year
```

### Working from a PRD or Linear issue

```
/agent-pipeline:pipeline --spec ENG-123 --spec ~/Downloads/rate-limits-prd.pdf
```

Subagents never see your conversation, and they can't call Linear or other connectors. So the orchestrator fetches each `--spec` once (a local file, a URL, or a Linear ID via your session's Linear connector) and saves a copy as Markdown in `.claude/pipeline/context/`, with an `INDEX.md` that gives every requirement a stable tag. Every agent reads that folder first.

- **Nothing is committed.** `.claude/pipeline/` is listed in your clone's `info/exclude`, not in `.gitignore`.
- **Everyone reads the same copy.** If the ticket is edited mid-run, the stages still agree.
- **Traceable.** The plan tags each acceptance criterion with its source requirement, tests carry the tags, the reviewer checks every requirement, and the PR body has a requirement → criterion → test table.
- **Linked, not closed.** A Linear ID goes into the branch name (`pipeline/eng-123-…`), so Linear links the PR. The PR says `Refs ENG-123`, not `Fixes`, so merging doesn't close the issue.
- **Worktrees:** git doesn't copy ignored files into a new worktree, so the orchestrator copies `context/` across from the main checkout, or fetches the specs again.
- Text in a spec that addresses an AI is treated as data. It's flagged, not obeyed.

### Properties, invariants and the mutation check

Passing tests only show that the cases someone wrote down work. The pipeline also looks for what must hold for **every** input and order of operations, and checks that the tests would actually catch a broken implementation.

1. **Discovery.** The planner reads `PROPERTY-DISCOVERY.md`, works through its checklist of property patterns (state-machine model, nothing lost, round-trip, rejected means no effect, consistency between two views, …) and lists candidates in `PLAN.md`. Then `property-finder` makes its own list without seeing the planner's, and the orchestrator merges the two. Each candidate is marked **test**, **covered** (by a named existing test), **reject** (with a reason) or **ask**. An **ask** depends on a product decision, so it goes to you in the assumptions check-in rather than being guessed.
2. **Property tests.** The test-writer writes a property-based test for each **test** row, using the library `detect-stack` found (fast-check, Hypothesis, proptest, jqwik, …). fast-check is used only in unit tests, never in integration or end-to-end tests; a property that needs the app is extracted into a pure function, or covered by example tests at that level. If the repo has none, the plan proposes adding one, and you can decline it at the check-in.
3. **Mutation check.** After the tests go green, the `mutator` breaks the code once per criterion and property (flip a condition, drop a field, skip a write, loosen a strict check), checks that a test fails, and restores the code. It also tries to evade guard tests such as source scans and import checks (code after a `//` inside a string, another import path, aliasing). If a mutation or evasion survives, the test-writer adds a test or strengthens the guard.
   Mutation testing can only weaken checks that exist. It can't notice strictness that was never written (an input the code never validates), so a high score says the written code is tested, not that it's secure.
4. **No weakened tests.** The orchestrator rejects test diffs that delete tests or assertions, add skip/only markers, or lower property run counts. A hook stops the implementer and the mutator from editing tests at all.
5. **Rejected isn't dropped.** A rejected property must cite the code, doc or test that justifies it. One rejected because a caller owns it becomes an *obligation on callers*: written into the function's doc comment, listed in the PR, and recorded in `INVARIANTS.md`.
6. **The registry grows.** After the run, lasting properties and caller obligations are added to `INVARIANTS.md` with the tests that guard them, so the next run starts from them. The pipeline adds rows but never removes or weakens one; it proposes those changes in its report instead.

Both files live in `.claude/pipeline/verification/` in your repo:

```
.claude/pipeline/
├── config.json                  # detected commands, run command, conventions (per clone)
├── context/                     # saved --spec sources (per run)
├── PLAN.md, ADR.md              # working files (per run)
├── runs/<slug>.json             # run state, for --resume (per run)
├── allow-check-config.txt       # check-config files the plan allows the implementer to write (per run)
├── logs/                        # test, CI and evaluator output (per run)
└── verification/
    ├── PROPERTY-DISCOVERY.md    # method and pattern checklist (kept, yours to edit)
    └── INVARIANTS.md            # registry of invariants and their tests (kept, grows)
```

- **Never checked in.** Like the rest of `.claude/pipeline/`, the folder is listed in your clone's `info/exclude`. Your repo and its `.gitignore` aren't touched. The PR body carries the property table and mutation results for reviewers.
- **Seeded once, then yours.** On the first run, the pipeline copies generic versions from the plugin. Add your codebase's own patterns and examples to `PROPERTY-DISCOVERY.md`; later runs use your copy and never overwrite it. When a plugin update brings new patterns, the pipeline says so and offers to add the missing sections to your copy, leaving your text alone; agents also read the plugin's copy in the meantime.
- **Per clone.** Since it isn't committed, each clone has its own registry. To share one across a team, copy the files somewhere you choose; if a repo already commits its own invariant docs (for example `docs/verification/INVARIANTS.md` or rules in `AGENTS.md`), every agent reads them as well, but the pipeline never edits them.
- **Worktrees** share the main checkout's folder through a symlink, so rows added in any worktree land in one place.

### Security-sensitive changes

The planner starts `PLAN.md` with `Security-sensitive: yes — <why>` when the change touches auth, sessions, crypto, secrets, money, identity verification, permissions or another trust boundary (the orchestrator can also set it). That switches on:

- **Trust-boundary property patterns** from `PROPERTY-DISCOVERY.md`: hostile and out-of-domain input (wrong runtime types, `NaN`, `1e300`, future timestamps, corrupt rows), domain separation and replay, the attacker's total budget when functions compose, and faults vs refusals vs corruption. For this code the generators must reach states the app normally can't.
- **A failure classification** in the plan: each failure is a caller fault, a server/config fault or corrupt data, with its outcome and whether it's reversible. Caller and server faults may not destroy user-owned state. "Fail closed" means deny now, not lock or delete.
- **Evidence for every dismissal.** An accepted risk or rejected property that doesn't cite code, docs or a test becomes an open question.
- **Strict oracles.** Reference models in property tests are written from the spec (`=== true`, exact types), never copied from the code's shape.
- **The `property-finder` runs even with `--fast`.**
- **A red-team `security-reviewer`** runs in parallel with the reviewer and tries to break the code. Neither accepts "it's validated elsewhere" for an exported trust-boundary function: a missing local defence is must-fix.
- **No ready PR with open security findings.** When the review loop stops (at most three fix rounds, earlier if a round fixes nothing), any confirmed finding still open makes the pipeline ask you, or with `--auto` open a draft with the findings at the top.

Every run, security-sensitive or not, also lists local conventions from neighbouring code (for example, closed schema objects) as constraints, writes an "Obligations on callers" section when a module is built ahead of its caller, and keeps bounds that are checked in two places in one shared constant.

### Held-out tests

The implementer can't edit tests, but it can still read them and build exactly what they check. So the test-writer also writes a held-out set: for each acceptance criterion, at least one more test through different inputs, paths or entry points. Those files are moved into git's own directory (`<git-common-dir>/agent-pipeline/holdout/<slug>/`, outside every worktree, so no test runner or search crawls them) before the red commit, and a hook stops the implementer and the mutator from reaching them by path. After green, the orchestrator copies them back and runs them.

- **All pass:** they're committed as `test: held-out acceptance tests` and count in the mutation check.
- **Some fail:** the implementation fits the tests but not the criterion. The implementer gets the criterion and the expected-versus-actual message, but not the test, for one round. The test-writer then checks any that still fail against the spec, since the test may be the thing that's wrong.
- The PR body reports how many held-out tests failed on the first try: a direct measure of overfitting.

### Exercising the running system

Tests are written by the same pipeline as the code, so they can share its blind spots. After the mutation check, the `evaluator` starts the system with the `run` command `detect-stack` found, checks each acceptance criterion the plan marks `[system: …]` through its real interface (`curl`, the CLI, Playwright when the repo has it), tries the neighbouring flows, and stops what it started. A criterion it can't reach because something is missing locally (a database, a secret, a device) is reported as not exercised, not as a failure. Its failures go through the same verify-then-fix loop as review findings.

### Landing the PR

Opening a PR is not the same as getting it merged. After `gh pr create`, the pipeline repeats until the PR is mergeable, it stops making progress, or 4 rounds pass:

1. **CI.** It waits for the checks. For each failure it reads the log and decides whether the branch caused it (reproduce locally, fix through the stage that owns the file, push), the target branch already fails it (listed for you, not fixed), or it's a flake (re-run once).
2. **Conflicts.** It merges the target branch (the default branch, or `--base`) in, resolving through the implementer and test-writer and regenerating lockfiles with the repo's own commands. It never rebases or force-pushes a pushed branch.
3. **Review comments.** Comments from review bots are verified like any finding, fixed if confirmed, and answered in their thread with the fixing commit or the evidence. A person's request for a specific change is handled the same way; a person's question or design point is left for you.

It never merges, enables auto-merge, approves, dismisses a review or resolves a person's thread. The final report says whether the PR is mergeable and what it's waiting on.

### Resuming a run

After each stage, the orchestrator writes `.claude/pipeline/runs/<slug>.json` (in the main checkout, so any worktree finds it): the branch, base, commits so far, the last completed stage, held-out files, loop progress and the PR. `/agent-pipeline:pipeline --resume` checks that the branch still matches the recorded commits and continues from the next stage. Work from a stage that didn't finish is noted and discarded, on the pipeline's own branch only.

### Branch hygiene

- **Uncommitted changes** in your checkout are never stashed or discarded. You're asked whether to build on them, run in a new worktree, or stop; with `--auto` the run moves to a new worktree.
- **Preflight** checks whether HEAD is the default branch tip. If not, it lists the commits that would ride along and asks whether to start from the default branch instead (with `--auto`, it keeps them and warns). With `--base`, the run starts from that branch's tip instead, so nothing from HEAD rides along.
- **Before the PR**, it compares every file in the diff against the target branch (the default branch, or `--base`) with the plan's "Affected code", asks about anything outside it, and lists what stays under "Changes outside the plan" in the PR body.
- **Hooks are never skipped.** The `guard-git.sh` hook blocks `--no-verify`, `git commit -n`, `core.hooksPath` overrides and `HUSKY=0`/`SKIP=` on commit or push, for pipeline subagents and for the main session while it's on a `pipeline/*` branch. If you really need to bypass a hook, run the command yourself in a terminal.

To open a PR it needs `gh` installed and authenticated (`gh auth login`). Without it, the pipeline prints the branch and PR body instead.

## Requirements

- Claude Code 2.1.292+ (for `plugin install --marketplace`)
- git, and `jq` or `python3` for the guard hooks (stock macOS has both)

## Develop

```bash
claude plugin validate . --strict
claude --plugin-dir .          # try it without installing
bash tests/guard-tests.test.sh # test-file guard hook tests
bash tests/guard-git.test.sh   # git-hook bypass guard tests
bash tests/guard-checks.test.sh # suppression, check-config and held-out guard tests, and the diff scan
```

## License

MIT
