# Formal Model: Claim Ledger (single-store)

This file covers `ClaimLedger.tla`, which models the `single-store` deployment
mode of the claim/lease protocol in `spec/08_CLAIMS.md`. For the `federated`
mode see [CLAIM_FEDERATED.md](CLAIM_FEDERATED.md).

The model is intentionally small and bounded. It does not encode ref plumbing,
signature verification, JSON parsing, or glob matching. It keeps exactly the
machinery that decides whether two actors can end up mutating overlapping paths
at the same time:

- a single ledger ref advanced by compare-and-swap (spec §9.1),
- wall-clock leases with per-actor clock skew (§8.1–§8.3),
- `lease_seq` fencing at the gate (§8.4),
- the deadline obligation on an in-flight operation (§8.5),
- delta authorization for deleting another actor's claim (§6),
- reader/writer conflict semantics (§7.1).

"Critical section" (CS) models the window in which an actor is actually
mutating the paths it claimed.

## Bounds

| Parameter | Value |
|-----------|-------|
| Actors | 2 |
| Resources (abstract paths) | 2 |
| Claim slots | 3 |
| Clock offsets | −1, 0, +1 (`MaxSkew` = 1) |
| Lease duration | 2 ticks |
| Time horizon | 5 ticks |
| Trace length checked | 8 (safe), 10 (counterexample matrix) |

## Properties

| Property | Statement | Clause |
|----------|-----------|--------|
| `MutualExclusion` | No two actors are in overlapping critical sections unless both are readers | §7.1 |
| `LedgerConflictFree` | The ledger never holds two live conflicting claims | §7.2 |
| `NoPrematureReap` | A claim is never removed while its holder still believes it live | §8.3 |
| `CSLeaseValid` | An actor in a critical section still owns the lease it entered under | §8.4, §8.5 |

`MutualExclusion` is the property that matters operationally; the other three
are the internal invariants that produce it.

### There is no global clock

`expires_at` is written in the holder's clock frame and read by peers in theirs.
An earlier version of this model asserted a global `TrulyExpired(c) == cExp[c]
<= now`, which Apalache refuted in four steps against an otherwise correct
protocol. That was a defect in the invariant, not the protocol, but it exposed
real imprecision in the specification and is why §8.2 now exists.

The frame-correct ground truth is the holder's own view of its own deadline:

```tla
HolderExpired(c) ==
  IF cHolder[c] = NoneActor
  THEN TRUE
  ELSE cExp[c] <= now + offset[cHolder[c]]
```

## Configuration Matrix

Each CONSTANT disables exactly one normative requirement. `ClaimsSafe.cfg`
enables all of them; every other config differs from it in exactly one knob, so
a counterexample attributes cleanly to a single clause.

| Constant | TRUE | FALSE |
|----------|------|-------|
| `AtomicCAS` | Commit only if the ledger has not moved and the conflict check still passes (§9.1 step 7) | Check-then-act |
| `UseFencing` | Entering the CS re-reads the ledger and requires holder and `lease_seq` to match (§8.4) | Proceed on the actor's own belief |
| `DeltaAuth` | Another actor's claim may be deleted only if expired under the peer rule (§6 case b) | Anyone may delete anything |
| `SkewAsymmetry` | Peer expiry applies the allowance, own expiry does not (§8.3) | Both use the raw comparison |
| `SkewAllow` | Allowance in ticks; must be ≥ `2 * MaxSkew` | — |
| `CSWatchdog` | Time cannot pass an in-CS actor's own deadline (§8.5) | Leases may expire mid-operation |

## Results

Apalache 0.52.2.

`ClaimsSafe.cfg` at `--length=8`: **NoError**. All four invariants hold across
every reachable state within 8 steps (12m09s wall, 679s solver).

Every disabled requirement produces a counterexample. The first column is the
run with all four invariants enabled (Apalache halts at the first violation);
the second is the same config checking `MutualExclusion` alone, to confirm the
break reaches the operationally meaningful property rather than only an internal
one.

| Config | Clause disabled | First violation (steps) | `MutualExclusion` (steps) |
|--------|-----------------|-------------------------|---------------------------|
| `ClaimsNoCAS` | §9.1 step 7 | `LedgerConflictFree` (4) | violated (6) |
| `ClaimsNoFencing` | §8.4 | `CSLeaseValid` (5) | violated (8) |
| `ClaimsNoDeltaAuth` | §6 case b | `NoPrematureReap` (3) | violated (7) |
| `ClaimsNoSkewAsym` | §8.3 | `NoPrematureReap` (3) | violated (6) |
| `ClaimsSmallAllow` | §8.3 bound | `NoPrematureReap` (4) | violated (7) |
| `ClaimsNoWatchdog` | §8.5 | `CSLeaseValid` (5) | violated (8) |

No clause in §6 through §9 is decorative.

### Counterexample shapes

Transition indices refer to the `Next` disjuncts: 0 `Tick`, 1 `PrepareAcquire`,
2 `CommitAcquire`, 3 `AbortStage`, 4 `Renew`, 5 `Release`, 6 `Reap`,
7 `EnterCS`, 8 `ExitCS`, 9 `Idle`.

- **NoCAS** — `Prepare, Prepare, Commit, EnterCS, Commit, EnterCS`. Both actors
  observe the resource free before either writes. Classic check-then-act.
- **NoFencing** — `Prepare, Commit, Tick, Tick, Prepare, EnterCS, Commit,
  EnterCS`. An actor walks into the critical section on a token that expired
  while it was idle.
- **NoDeltaAuth** — `Prepare, Commit, EnterCS, Reap, Prepare, Commit, EnterCS`.
  A peer deletes a live claim out from under an actor already mutating.
- **NoSkewAsym** — `Prepare, Commit, EnterCS, Prepare, Commit, EnterCS`. Six
  steps, no tick required: the clock offset alone is enough for one actor to
  judge a live claim expired.
- **SmallAllow** — same shape plus one tick. `SkewAsymmetry` is *on* and the
  allowance is *positive*; it still breaks at `SkewAllow = MaxSkew`. This is
  what forces the `SkewAllow >= 2 * MaxSkew` bound in §8.3.
- **NoWatchdog** — `Prepare, Commit, Tick, EnterCS, Tick, Prepare, Commit,
  EnterCS`. Every other requirement is enabled. An actor enters legitimately,
  its lease expires while it is still working, and a peer acquires the same path
  entirely correctly. Fencing does not catch this because fencing guards the
  transition, not the duration — which is why §8.5 exists.

## Running

```sh
just formal-claims              # safe config, length 8
just formal-claims-matrix       # all six counterexample configs
```

Or directly:

```sh
apalache-mc check --config=formal/ClaimsSafe.cfg --length=8 formal/ClaimLedger.tla
apalache-mc check --config=formal/ClaimsNoCAS.cfg --length=8 formal/ClaimLedger.tla
```

The `Claims*.cfg` files check all four invariants; the `Mx*.cfg` files check
`MutualExclusion` alone.

## Limitations

- Two actors and two resources. Sufficient for mutual exclusion, which is a
  pairwise property, but it does not exercise contention fairness or the
  retry-exhaustion path of §9.2.
- Bounded trace length. This is bounded model checking, not a proof: it
  establishes that no violation exists within 8 (respectively 10) steps of the
  initial state, not that none exists at all.
- The single-store deployment mode of §9.3 is what is modelled. Federated mode
  is covered separately in `ClaimFederated.tla`.
- **Administrative steal (§6 case c) is not modelled here.** The NoError result
  above is therefore conditional on steals not being used. Modelling steal in
  the federated module refuted the original §6 formulation; see
  [CLAIM_FEDERATED.md](CLAIM_FEDERATED.md). The revoke-then-expire fix in §6.2
  applies to both modes.
- Clock offsets are fixed at initialization. Drift during a run is not modelled.
- `CSWatchdog` is an assumption about implementation behaviour, not a protocol
  mechanism. The model shows the assumption is necessary; discharging it is an
  obligation on implementations (§8.5).
