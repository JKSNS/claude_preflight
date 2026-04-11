# ARCHITECTURE

Authoritative description of how this system is built. The agent verifies architectural claims here against the current repo before acting on them; stale claims are flagged by `scripts/governance-check.sh` (architecture drift).

## Format

```
## <component>

Purpose:        <one sentence>
Lives in:       <relative path or paths>
Depends on:     <other components or external services>
Consumed by:    <other components or external callers>
Notable invariants: <what must be true for this component to be correct>
```

## Components

> Replace this section with project-specific components. Run `/graphify .` first to derive the initial layout from the codebase.
