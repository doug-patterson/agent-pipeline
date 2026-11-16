# Invariants

Things that must always be true in this repo, for every input and every order of operations. Each one has an ID, the source it comes from, and the tests that guard it.

This file lives in `.claude/pipeline/verification/`, which git ignores in this clone. The agent-pipeline reads it before planning and adds rows after a run. You can edit it by hand too.

- **The pipeline may add** rows, and may add tests to a row.
- **Only a human removes a row or weakens its statement.** The pipeline proposes such a change in its final report instead of making it.
- A row with no test is a gap. List it under "Open gaps".
- A row the current code breaks is marked **BROKEN**, with the test that shows it.

| ID | Invariant (for all inputs and sequences…) | Source | Guarded by |
|---|---|---|---|

## Open gaps

