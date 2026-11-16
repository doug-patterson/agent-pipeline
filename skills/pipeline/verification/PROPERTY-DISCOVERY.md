# Property and invariant discovery

This file lives in `.claude/pipeline/verification/`, which git ignores in this clone. The agent-pipeline seeds it from the plugin the first time it runs here, then leaves it alone. Edit it to add patterns and examples from this codebase; the pipeline reads your copy.

The aim is to find what must **always** hold for the code a change touches: for every input, every order of operations, and every failure. Examples from a spec only cover the cases someone thought of. Properties catch the ones nobody did.

## Steps

1. **Collect what already exists.** Read the rows of `INVARIANTS.md` (next to this file) that cover the files in scope, plus any invariants or verification docs the repo itself commits (for example `docs/**/INVARIANTS.md`, or rules in `AGENTS.md` or `CLAUDE.md`). Each of them must still hold after the change.
2. **Go through the checklist below** for each function, state machine or endpoint the change touches. Write down every candidate, even ones you expect to reject.
3. **Get a blind second list.** The `property-finder` agent works from the specs and the files in scope, without seeing the planner's list.
4. **Merge and sort** each candidate into one of:
   - **test**: write a property or example test for it;
   - **covered**: an existing test already guards it (name the test);
   - **reject**: false, too expensive, or out of scope (say which);
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
| **Consistency between two views** | Do two functions that should agree always agree? | `isValid(x)` is true exactly when `errors(x)` is empty; a list endpoint and a detail endpoint report the same status |
| **Metamorphic / monotonic** | If I change the input in a known direction, does the output move the way it should? | Adding an item never lowers a cart total; a stricter filter never returns more results |
| **Derived equals source** | Is a derived value always recomputable from its source? | A cached total equals the sum of its line items |
| **Order independence** | Does input order matter when it shouldn't? | Output doesn't depend on the order of keys or tags in the input |
| **Boundaries** | What happens at empty, maximum size, whitespace only, or Unicode? | A payload at exactly the size limit; whitespace-only input |
| **Concurrency and timing** | What happens with interleavings: edit during save, two clients, retry after failure? | Two clients write from the same version; an edit arrives while a save is in flight and the save then fails |
| **Scope and isolation** | Can data from another user, tenant or context leak in? | A query never returns rows from another tenant |
| **Spec rule as a property** | Can each rule in the spec be stated as "for all …"? | "For every order and every discount code, the total is never negative" |

## Writing good generators

- Build inputs **the way the app builds them**: fold random sequences of real operations over a real starting state. This keeps inputs valid and failures meaningful. Don't generate states the app can't reach.
- Include failures and odd timings as operations (failed save, stale version, retry, edit during save), not only the happy path.
- Bias the mix towards the interesting cases, for example picking "stale" more often than its natural rate.
- Keep values small so the library can shrink a failure to a readable counterexample.
- Don't pin seeds or lower the run count to make a test pass. Keep each property file fast (a couple of seconds).
- When a property finds a counterexample, copy the shrunk case into an ordinary example test so it stays as a named regression.

## When to ask a human

Ask before encoding an invariant when:
- it would fix a business or domain rule the sources don't state;
- it contradicts a source, or two sources disagree;
- satisfying it would change what users see in a way the spec doesn't ask for.

An invariant you merely guessed is worse than no invariant, because a green test then makes the guess look verified.
