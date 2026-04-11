# THREAT MODEL

Required for tier 2+ projects. Authoritative description of the assets, attackers, trust boundaries, abuse cases, and mitigations for this system.

## Assets

> What is valuable here that an attacker would want? (data, credentials, compute, reputation, money, availability)

## Attackers

> Who would attack this and why? (external opportunist, targeted external, insider, supply-chain compromise, malicious agent)

## Trust boundaries

> Where does data or control cross a boundary between code we trust and code we don't? (network ingress, untrusted file inputs, dependency code, agent-generated commands)

## Abuse cases

> Concrete misuse scenarios. Each case: actor, capability, asset targeted, defenses that should prevent it, defenses that actually do prevent it.

## Mitigations

> Pointer to `policy/`, hooks, CI checks, and code paths that implement each defense. Cross-reference with `governance/policy-map.md`.

## Out of scope

> What this threat model intentionally does not cover, and why.
