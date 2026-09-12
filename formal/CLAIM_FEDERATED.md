# Formal Model: Claim Ledger (federated)

This file covers `ClaimFederated.tla`, which models the `federated` deployment
mode of the claim/lease protocol in `spec/08_CLAIMS.md` (§9.3). For
`single-store` mode see [CLAIM_LEDGER.md](CLAIM_LEDGER.md).

In `single-store` every actor shares one ref store, so a local compare-and-swap
*is* the lock. Federated mode removes that: each actor holds its own clone, a
claim only counts once its ledger push has landed, and every replica's view of
the ledger lags the remote. The interesting failures all live in that lag.

## What the model captures

- An authoritative remote ledger plus a per-actor `base`, the remote version
  each replica last fetched.
- **Conflict checks run against the actor's own stale replica.** It cannot see a
  peer's claim pushed after its last fetch, nor a peer's unpushed claim at all.
- Fast-forward push: a push is refused unless the replica is current. A refused
  push forces a fetch and re-derivation.
- **Removal is a tombstone, not a delete.** Records carry `rAddedAt` and
  `rRemovedAt` so a stale replica can still observe a claim that is already gone
  upstream. Modelling removal as instantly visible would make replicas *fresher*
  than reality — the unsound direction, which would hide bugs.
- Claim slots are single-use, standing in for UUID uniqueness.

Skew handling (§8.3) and the deadline obligation (§8.5) are hardcoded to their
correct behaviour here; they are exercised as knobs in `ClaimLedger.tla`.

## Bounds

| Parameter | Value |
|-----------|-------|
| Actors | 2 |
| Resources (abstract paths) | 2 |
| Claim slots | 3 |
| Remote versions | 5 |
| Clock offsets | −1, 0, +1 (`MaxSkew` = 1, `SkewAllow` = 2) |
| Lease duration | 2 ticks |
| Time horizon | 3 ticks |

## Properties

| Property | Statement | Clause |
|----------|-----------|--------|
| `MutualExclusion` | No two actors mutate intersecting paths concurrently unless both are readers | §7.1 |
| `RemoteConflictFree` | The authoritative ledger never holds two live conflicting claims, however stale the replicas that produced them | §7.2 |
| `CSLeaseValid` | An actor in a gated operation owns a live, published, matching lease | §7.3, §8.4 |
| `EstablishedMatchesRemote` | An established claim's local record agrees with the published one | §7.3 |

### Non-vacuity

A NoError result is only meaningful if the model reaches the states in
question. Four witness invariants are written to be **violated**; a
counterexample is the proof of reachability. All four are violated at
`--length=10`:

| Witness | Proves reachable |
|---------|------------------|
| `WitnessEstablishedCS` | an actor in a gated operation holding a published claim |
| `WitnessTwoEstablished` | two actors holding published claims simultaneously |
| `WitnessStaleReplica` | a replica behind the remote |
| `WitnessRebaseDrop` | a rebase that actually invalidates a pending claim |

The last one matters most: without it, `RevalidateOnRebase` could be dead code
and its counterexample meaningless.

## The defect this model found

`FedSafe` — every requirement in the specification enabled — **violated
`CSLeaseValid` in five steps**:

```
AcquireLocal(a2)   a2 takes a write claim on r1
Push(a2)           published at version 1; a2's claim is now established
EnterCS(a2)        a2 passes the fence legitimately and starts mutating r1
Fetch(a1)          a1 catches up to version 1
Steal(a1)          a1 removes a2's live claim; remote is now at version 2
```

`a2` is still mutating `r1`. Its `base` is 1, the removal landed at version 2,
so it cannot observe the removal. A peer is free to acquire `r1` immediately.

**§6 deletion case (c) was unsound as written.** This is not federated-specific
— the same hazard exists in `single-store` — but federation makes it
undeniable, because the victim *provably* cannot see the deletion until it
fetches. The single-store model missed it only because it did not model steal
at all.

### The fix

§6.2 now specifies that **a steal revokes rather than deletes**. It sets a
`revoked` field which blocks renewal (§8.6); the claim then expires on its own
schedule and is removed by ordinary reaping. The exclusion window is never
shortened below the victim's own `expires_at`, so the victim's deadline
obligation (§8.5) guarantees it has stopped before anyone else can acquire.

This is ordinary lease-revocation practice: a lock cannot be yanked from a live
holder, only allowed to lapse.

`FedUnsafeSteal.cfg` pins the old behaviour and reproduces the violation, so the
defect stays regression-tested.

## Results

Apalache 0.52.2.

`FedSafe.cfg` at `--length=7`: **NoError** (6m07s, 379s solver). All four
invariants hold across every reachable state within 7 steps of initialization.

| Config | Requirement disabled | Outcome | Violation | Steps |
|--------|----------------------|---------|-----------|-------|
| `FedSafe` | — | **NoError** | — | — |
| `FedNoEstablish` | §7.3 establishment | Error | `CSLeaseValid` | 2 |
| `FedNoFF` | §11.2 fast-forward | Error | `RemoteConflictFree` | 4 |
| `FedNoRevalidate` | §11.2 re-derive | Error | `RemoteConflictFree` | 5 |
| `FedUnsafeSteal` | §6.2 revoke-not-delete | Error | `CSLeaseValid` | 5 |
| `FedNoFetchFence` | §8.4 fence freshness | **NoError** | — | — |
| `FedNoFetchFenceNoSteal` | §8.4 freshness, steals off | **NoError** | — | — |

Two observations worth keeping:

- **`FedNoEstablish` breaks in two steps** — acquire locally, enter the critical
  section. Treating a locally committed claim as a lock fails immediately and is
  the single most important thing federated mode gets wrong if implemented
  naively.
- **Fast-forward alone is insufficient.** `FedNoRevalidate` keeps FF enabled and
  still lands two conflicting claims on the remote: the rejected pusher fetches,
  becomes current, and then pushes its stale claim legitimately. §11.2's two
  requirements are jointly necessary, not alternatives.

### Resolved: no fetch is required at the fence

`FetchBeforeFence` required an up-to-date replica before §8.4's fence check.
Disabling it is **NoError** at `--length=7`, both with steals enabled
(`FedNoFetchFence`) and disabled (`FedNoFetchFenceNoSteal`). The requirement was
unjustified and has been removed from §8.4.

Before the steal fix, disabling it *did* violate in 5 steps — but that
counterexample depended entirely on instant-delete steals. Once §6.2 made steals
revoke rather than delete, the hazard disappeared.

The underlying argument, which the model confirms: a claim can leave the ledger
only by holder release, expiry-based reaping (§6 case b), or lapse-after-
revocation (§6.2). The latter two both require peer-expiry, which given
`SkewAllow >= 2 * MaxSkew` implies the holder's own strict deadline has passed.
An actor that passes its own expiry check therefore cannot have had its claim
removed by anyone, no matter how stale its replica is.

This takes a network round trip off the acquisition hot path — the practical
payoff of having modelled federated mode at all.

## Running

```sh
just formal-federated            # safe config, length 7
just formal-federated-matrix     # the four counterexample configs
```

Apalache's launcher hardcodes `-Xmx4096m`, which gets these runs OOM-killed on a
loaded machine and is slower besides. The justfile exports `JVM_ARGS=-Xmx1800m`;
set it if invoking `apalache-mc` directly:

```sh
JVM_ARGS=-Xmx1800m apalache-mc check --config=formal/FedSafe.cfg \
  --length=7 formal/ClaimFederated.tla
```

## Limitations

- Two actors, two resources, one remote. Mutual exclusion is pairwise so two
  actors suffice for it, but three-replica interleavings and partial partitions
  are not explored.
- Bounded trace length. NoError at length 7 means no violation within 7 steps of
  initialization, not that none exists.
- The remote is a single always-available server. Push rejection is modelled;
  network partition, packet loss, and partial pushes are not.
- Clock offsets are fixed at initialization; drift during a run is not modelled.
- Ref-level mechanics — signature verification, commit chaining, the tree diff
  authorization of §6 — are abstracted away. The model checks the *protocol*,
  not its Git encoding.
- Contention fairness and the retry-exhaustion path of §9.2 are not checked.
  Nothing here says an actor eventually acquires; these are safety properties
  only.
