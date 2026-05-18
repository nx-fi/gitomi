# Formal Model: GitHub Live Sync

This directory models the Gitomi <-> GitHub live-sync identity protocol with
Apalache/TLA+.

The model is intentionally small and bounded. It does not encode issue bodies,
comments, labels, or full RBAC. It focuses on the part that must be correct for
eventual consistency: every logical issue/pull must converge to one native
Gitomi object and at most one GitHub number, even when multiple maintainers run
live sync, go offline, or run only one direction for a while.

## Scenario Matrix

The model covers these classes of behavior:

| Scenario | Risk | Required protocol property |
| --- | --- | --- |
| GitHub-origin item imported by multiple downstream-only replicas while offline | Replicas allocate different Gitomi UUIDs for the same GitHub number | Deterministic import identity, or an online shared CAS before native object creation |
| Gitomi-origin item exported by one upstream runner, then imported by another replica with an empty private map | GitHub copy is imported as a second Gitomi object | Durable GitHub-number alias event on the shared bridge inbox |
| Gitomi-origin item exported by one runner, then later exported by another runner with an empty private map | Second runner creates a duplicate GitHub issue/pull | Exporter seeds its private map from shared aliases before creating |
| Two upstream-only runners export the same local Gitomi object concurrently before either alias is published | Duplicate GitHub issues/pulls | Shared export claim/lease or GitHub-side idempotency before create |
| GitHub already has an item, and an upstream-only runner exports a local object for the same logical item without importing first | Duplicate GitHub issue/pull | Export create must first establish that GitHub has no existing item for that logical identity |
| Downstream-only runner imports but does not push Gitomi refs | Other replicas do not see the import yet | Eventual consistency only holds once replicas eventually resume full Gitomi sync |
| Comment export/import | Same identity risk as issue/pull, but with GitHub comment database IDs | Needs durable comment aliases or deterministic comment identity; the current model tracks only issue/pull identity |

## Model Files

- `GitHubLiveSync.tla` is the parameterized model.
- `GitHubLiveSyncSafe.cfg` enables the protocol requirements that should hold
  for the desired eventual-consistency model:
  - deterministic imports,
  - export claims,
  - no outbound create when GitHub already has the logical item.
- `GitHubLiveSyncUnsafe.cfg` disables those requirements. It is expected to
  produce counterexamples to `Safety`, demonstrating why alias-after-create is
  not enough for simultaneous live-sync operation.

## Properties

`Safety` checks:

- a GitHub number alias always points to an object for the same logical item,
- no logical item has more than one GitHub number,
- no logical item has more than one native Gitomi object anywhere in the system.

`ConvergenceAfterSettle` checks a bounded settle phase. After arbitrary active
steps, the model can switch to a phase where every user is full-syncing and no
new local/GitHub writes occur. One abstract settle sweep represents the
eventual full import/export/fetch/push closure. The invariant requires all
replicas, the remote Gitomi state, GitHub numbers, and bridge aliases to agree
after that sweep.

This is a bounded convergence check, not a fairness proof over an unbounded
network. It is designed to make the eventual-consistency assumptions explicit
and executable.

## Running

Safe protocol:

```sh
apalache-mc check --config=formal/GitHubLiveSyncSafe.cfg --length=4 formal/GitHubLiveSync.tla
```

Counterexample-oriented unsafe protocol:

```sh
apalache-mc check --config=formal/GitHubLiveSyncUnsafe.cfg --length=4 formal/GitHubLiveSync.tla
```

The unsafe run should fail `Safety`. Typical counterexamples are:

- two downstream-only importers allocate different Gitomi objects for the same
  GitHub number, or
- an upstream-only exporter creates a second GitHub number for a logical item
  that already exists on GitHub.

## Design Implication

The full live-sync mental model needs stronger guarantees than a local private
map plus alias publication after successful export:

1. Imports from GitHub must be deterministic for issue/pull identity, or must
   use a shared remote CAS before creating a native Gitomi object.
2. Exports to GitHub must reserve the logical item through a shared claim/lease
   or use a GitHub-side idempotency mechanism before creating a GitHub issue or
   pull request.
3. Exporters must treat durable bridge aliases as input to their private map.
4. Eventual consistency only applies after partitions heal and actors resume
   enough bidirectional Gitomi/GitHub sync to exchange refs, aliases, and API
   state.
