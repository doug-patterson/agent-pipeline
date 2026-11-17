# Property and invariant discovery

<!-- agent-pipeline seed: 0.5.0 -->

This file lives in `.claude/pipeline/verification/`, which git ignores in this clone. The agent-pipeline seeds it from the plugin the first time it runs here, then leaves it alone. Edit it to add patterns and examples from this codebase; the pipeline reads your copy. (The marker line above says which plugin version seeded it; the pipeline uses it to tell you when newer patterns are available.)

The aim is to find what must **always** hold for the code a change touches: for every input, every order of operations, and every failure. Examples from a spec only cover the cases someone thought of. Properties catch the ones nobody did.

## Steps

1. **Collect what already exists.** Read the rows of `INVARIANTS.md` (next to this file) that cover the files in scope, plus any invariants or verification docs the repo itself commits (for example `docs/**/INVARIANTS.md`, or rules in `AGENTS.md` or `CLAUDE.md`). Each of them must still hold after the change.
2. **Go through the checklist below** for each function, state machine or endpoint the change touches. Write down every candidate, even ones you expect to reject. If PLAN.md marks the change **Security-sensitive**, the patterns in the second table are mandatory, not optional.
3. **Get a blind second list.** The `property-finder` agent works from the specs and the files in scope, without seeing the planner's list.
4. **Merge and sort** each candidate into one of:
   - **test**: write a property or example test for it;
   - **covered**: an existing test already guards it (name the test);
   - **reject**: false, too expensive, or out of scope (say which, and cite the code, doc or test that shows it; see "Rejected is not dropped" below);
   - **ask**: it depends on a product judgment the sources don't settle. Ask a human; don't encode a guess.
5. **Write the properties**, then run the mutation check: each property should fail when its invariant is broken on purpose.

## Checklist of property patterns

| Pattern | Question to ask | Typical example |
|---|---|---|
| **State-machine model** | If I run any sequence of operations, does the real object agree with a simple model after every step? | A form's `dirty` flag equals "current value differs from the last value the server confirmed", after any sequence of edits and successful or failed saves |
| **Nothing lost** | Can any operation drop data the user entered without an explicit choice? | A merge or import keeps existing user text as an exact prefix |
| **Unchanged unless addressed** | Is everything the operation shouldn't touch byte-identical afterwards? | Updating one record leaves every other record and its history unchanged |
| **Exact pass-through** | Does the system store or send exactly what it was given, with nothing merged in? | The API stores the client's payload exactly, with no fields backfilled from elsewhere |
| **Round-trip** | Does `decode(encode(x))` give back `x`? Does load-then-save change nothing? | Parse then serialize a config file; load a record into a form and save with no edits |
| **Idempotence** | Does doing it twice equal doing it once? | Applying the same migration or normalization twice; retrying a request with the same idempotency key |
| **Rejected means no effect** | When an operation fails or is refused, is the state exactly as before? | A stale, invalid or oversized write changes no row |
| **Consistency between two views** | Do two functions, or two places, that should agree always agree? | `isValid(x)` is true exactly when `errors(x)` is empty; a list endpoint and a detail endpoint report the same status; the bounds a config schema enforces at boot equal the bounds the runtime checks, because both read one shared constant |
| **Metamorphic / monotonic** | If I change the input in a known direction, does the output move the way it should? | Adding an item never lowers a cart total; a stricter filter never returns more results |
| **Derived equals source** | Is a derived value always recomputable from its source? | A cached total equals the sum of its line items |
| **Order independence** | Does input order matter when it shouldn't? | Output doesn't depend on the order of keys or tags in the input |
| **Boundaries** | What happens at empty, maximum size, whitespace only, or Unicode? | A payload at exactly the size limit; whitespace-only input |
| **Concurrency and timing** | What happens with interleavings: edit during save, two clients, retry after failure? | Two clients write from the same version; an edit arrives while a save is in flight and the save then fails |
| **Scope and isolation** | Can data from another user, tenant or context leak in? | A query never returns rows from another tenant |
| **Spec rule as a property** | Can each rule in the spec be stated as "for all …"? | "For every order and every discount code, the total is never negative" |

### Trust-boundary patterns (mandatory when PLAN.md is Security-sensitive)

Use these for any code that sits on a trust boundary: auth, crypto, secrets, money, identity verification, permissions, or anything that accepts input from a caller it can't vouch for. They are worth a look for any exported function.

| Pattern | Question to ask | Typical example |
|---|---|---|
| **Hostile / out-of-domain input** | What does the function do with input its types say can't arrive? Try, on every argument and every field of every stored row: wrong runtime types passed through `unknown`/`any`/JSON (truthy non-booleans such as `'false'`, `1`, `{}`, a Promise; strings for numbers; `null`/`undefined`; arrays for objects); values just outside the valid domain on every axis (negative, zero, non-integer, huge such as `1e300`, `NaN`, `±Infinity`, empty and over-long strings); timestamps in the future and the far past, and clock skew between the caller and the stored row; malformed or partial stored rows. Every one must be refused or handled as the spec says, never accepted by accident. | `verify({codeMatches: 'false'})` is refused, not accepted by a truthy `if`; a row with `createdAt` in the future is treated as invalid, not as a code that never expires; a TTL of `1e300` or `2.5` is rejected, not used |
| **Domain separation / replay** | Can an artifact made here (hash, token, signature, MAC, code, nonce, cookie) be validated or replayed in another context, row, user, tenant, environment or product? Especially when a key, pepper or salt is shared with other code. | A code hash is computed over `purpose ‖ tenant ‖ row id ‖ code`, so a digest copied from another row, product or purpose never verifies here, even under the same pepper |
| **Composition budget** | When the functions combine, what is the attacker's (or a buggy client's) total allowance? Multiply the limits through every reset path. | "5 attempts per code" plus "a resend resets attempts" plus "5 resends a day" means 25 guesses per day per account; state it, test it, and check it against the spec |
| **Faults vs refusals vs corruption** | Classify every failure: a **caller fault** (bad input: refuse), a **server or config fault** (non-finite clock, bad policy, dependency down: report unavailable), or **corrupt stored data** (a row that can't be valid). Then check: does any caller fault or server fault have an irreversible effect on user-owned state? "Rejected means no effect" extends to faults: only genuinely corrupt data may trigger a destructive outcome (lock, delete, revoke), and then by an explicit, tested rule. | A non-finite `now` or an invalid policy returns `unavailable` and leaves the user's live code and its attempt count exactly as they were; it does not lock the code or wipe its hash |

## Rejected is not dropped

A **reject** row is a decision, so it has to leave a trace:
- Cite the code, doc or test that supports it (`file:line`, a doc section, a test name). A rejection with no citation is an open question: mark it **ask**.
- If the reason is "out of scope because another component or a future caller owns it", the property becomes an **obligation on callers**. Write it in PLAN.md's "Obligations on callers" section; the implementer puts it in the function's doc comment, the PR body lists it, and the pipeline records it in `INVARIANTS.md`. Never drop it silently. Typical obligations: apply a decision atomically with the read it was based on; a resend supersedes the old code; the caller must rate-limit before calling.

## Writing good generators

- For ordinary logic, build inputs **the way the app builds them**: fold random sequences of real operations over a real starting state. This keeps inputs valid and failures meaningful, and you shouldn't generate states the app can't reach.
- **For security, money or trust-boundary code, do the opposite as well.** Generating unreachable, corrupt and hostile states is required, because an attacker, a bug elsewhere or a bad migration will reach them. Add a second generator that produces the inputs from "Hostile / out-of-domain input": wrong types, out-of-domain numbers, future and past timestamps, malformed rows. Don't let the generator for valid inputs set the floor (for example, time offsets that are only ever `>= 0`).
- Include failures and odd timings as operations (failed save, stale version, retry, edit during save, a server fault mid-sequence), not only the happy path.
- Bias the mix towards the interesting cases, for example picking "stale" or "hostile" more often than its natural rate.
- Keep values small so the library can shrink a failure to a readable counterexample, but include the specific extreme values (`NaN`, `±Infinity`, `1e300`, `-0`, `Number.MAX_SAFE_INTEGER + 1`) as explicit constants in the mix.
- Write the **reference model independently of the implementation**, as strict as the spec: if the spec says "a boolean `true`", the model checks `=== true`, not truthiness. A model that copies the code's shape passes with the code's bugs.
- Don't pin seeds or lower the run count to make a test pass. Keep each property file fast (a couple of seconds).
- When a property finds a counterexample, copy the shrunk case into an ordinary example test so it stays as a named regression.

## When to ask a human

Ask before encoding an invariant when:
- it would fix a business or domain rule the sources don't state;
- it contradicts a source, or two sources disagree;
- satisfying it would change what users see in a way the spec doesn't ask for;
- a dismissal rests on a claim about other code that you can't find evidence for.

An invariant you merely guessed is worse than no invariant, because a green test then makes the guess look verified. The same goes for a risk you dismissed without evidence.
