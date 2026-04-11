# Regression hunter playbook

You are looking for behavior changes that the test suite will not catch. The premise: every line of changed code is a possible regression vector.

Check, in this order:

1. **Behavior diff** — for each modified function, what observable behavior changed? Inputs that previously returned X now return Y.
2. **Removed branches** — was a code path deleted that some caller (in this repo or out of it) might still depend on?
3. **Renamed exports / fields / args** — does anything outside this diff reference the old name? grep the repo before declaring it dead.
4. **Changed defaults** — did a default value, threshold, timeout, retry count, or feature flag flip?
5. **Order-of-operations** — did the sequence of side effects change in a way that's invisible to a unit test but visible to an integration test?
6. **Boundary conditions** — empty input, max input, off-by-one, unicode, null, zero-length collection.
7. **Error handling** — did this change swallow a previously-raised exception, or raise a new one that callers will not catch?
8. **Test coverage** — for each behavior change, is there a test that would have failed under the old code? If not, the test is not a regression test, it is a co-implementation.

For every finding:

```
SEVERITY:    low | medium | high
CONFIDENCE:  low | medium | high
EVIDENCE:    file:line of the behavior change
DEPENDENT:   files / callers / external systems that rely on the old behavior
TEST GAP:    the specific test (with name) that should exist
RISK:        what breaks in production if this regresses unnoticed
PROMOTE TO:  task | test | risk
```

A finding with `TEST GAP: <name>` is not closed until that test exists and proves the new behavior. "We added a test" is not enough — the test must exercise the boundary that was missed.
