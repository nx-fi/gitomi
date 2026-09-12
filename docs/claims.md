# Local path claims, supervised execution, and commit checks

`gt claim` implements local acquisition, renewal, reaping, supervised execution,
and the pre-commit conflict check from
[`spec/08_CLAIMS.md`](../spec/08_CLAIMS.md). Initialize Gitomi with `gt init`
and configure commit signing and verification as for other signed Gitomi writes.
The signing key must belong to an accepted device binding.

```sh
git config gitomi.claims.mode single-store
gt claim acquire 'src/auth/**' --ttl 15m --reason 'refactoring token validation' --json
gt claim renew <claim-id> --ttl 15m --lease-seq <captured-sequence> --json
gt claim check 'src/auth/**'
gt claim ls --all
gt peers 'src/auth/**'
gt claim release <claim-id>
```

`single-store` is the default and is reported in both text and JSON listings.
It applies when all actors share the same Git object/ref store, including linked
worktrees. Separate clones require federated establishment, which this version
does not implement: `gitomi.claims.mode=federated` refuses before writing.
Claims do not use inbox refspecs, reducers, quarantine, fetch, or push.

Paths are relative to the repository root, including when invoked from a
subdirectory. Quote wildcards so the shell does not expand them. Trailing `/`
means `/**`. Literal/glob matching is exact for ASCII; uncertain glob/glob or
Unicode intersections conservatively conflict. Read claims can share paths;
unknown stored modes act as write claims.

Claims held by the same `(principal, device, run_id)` never conflict. When several
agents share a configured device, give each a distinct UUIDv7 through
`GT_CLAIM_RUN_ID` or `--run-id`. The default run ID is empty. Keep that ID for the
agent's subsequent check/acquire calls. `release --all` releases the configured
principal/device's claims across runs; `release --run UUID` selects one run.
`ls --mine` selects the current triple; `ls --all` also includes expired entries.

Acquisition supports `--mode read|write`, `--ttl` (30s–4h; default 15m),
`--reason` (up to 1 KiB), `--wait [duration]` (default 5m), and `--json`.
Durations use `s`, `m`, or `h`. Check supports `--mode` and `--advisory-only`.
JSON acquire output includes `deployment_mode`, `established`, and the `claim`
record with its `claim_id`, `lease_seq`, and deadline. List output contains a
`claims` array. Displayed peer text is quoted/escaped, capped, and marked as data.

## Renewal and expiry collection

`gt claim renew <claim-id> [--ttl 15m] [--lease-seq N] [--run-id UUID] [--json]`
extends a live claim belonging to the current holder/run. `--ttl` measures the
new deadline from now and must extend the existing deadline. Renew when less
than one third of the lease remains; avoid renewing more often than every 30s.
The command preserves claim metadata and advances `lease_seq` by one. Capture
the returned sequence and deadline for subsequent operations. `--lease-seq N`
optionally requires your previously captured sequence, including after a CAS
retry; concurrent renewals using the same sequence cannot both succeed.

An absent, expired, revoked, differently held, or sequence-mismatched lease
returns **4**, with recovery instructions. Revocation keeps excluding peers
until expiry. Signing is followed by another old-deadline check before the CAS;
expiry during a slow signer refuses renewal. A deadline crossed during the ref
update also returns 4, even if the new record was published: stop work and
inspect the ledger before acquiring a fresh claim.

`acquired_at` never changes. Under the current record limit, no renewal may
extend a claim beyond four hours after its original acquisition. Choose a
shorter TTL or stop work, release, and acquire a new claim. Renewal does not
supervise an editor or command, arm a watchdog, or authorize work past a deadline.

Successful acquire, renew, and release writes also collect expired records when
there is room in the 512-action delta limit. Every collected record is strictly
past its deadline **plus 30s**, even for the writer's own claims and revoked
claims. Each deletion carries a `reap` action with the original `expired_at`.
Live claims retain their blob bytes; reads, conflicts, and other refusals do not
trigger a sweep. Additional expired records wait for a later write when the
action budget is full.

`gt peers [paths...]` shows one line per relevant live claim held by another
holder/run, including shared readers. It displays at most 50 claims, summarizes
paths and reasons, and reports omitted claims. It displays claim metadata, never
session transcripts. `--run-id UUID` or `GT_CLAIM_RUN_ID` identifies your run.

## Fenced execution and deadline supervision

Use the claim ID, sequence, and deadline returned together by acquisition or
renewal to run an abortable local command:

```sh
gt claim exec "$claim_id" --lease-seq "$lease_seq" --expires-at "$expires_at" \
  --run-id "$worker_id" -- git commit -m 'Update authentication'
```

The gate authenticates the local ledger and checks the exact holder/run,
sequence, and captured deadline before starting the command. A forged later
deadline, stale sequence, missing record, or wrong holder returns 4 without
starting it. There is no fetch, signing, or ledger write on this path. The
current implementation still requires single-store deployment.

Execution defaults to `--mode write`, which requires a write lease. Use
`--mode read` only for commands that read the claimed paths; either a read or
write lease can authorize those operations. Claims remain advisory: the command
must confine its repository mutations to its claimed paths. This wrapper does
not infer touched paths or enforce filesystem read-only access.

A separate Linux watchdog process is armed before the command may run. It aborts
at `expires_at - abort_margin`; `--abort-margin` defaults to 5s and accepts 1s to
1h. A lease already within that margin refuses execution. The watchdog uses an
absolute wall-clock timer and an elapsed-time timer that includes machine
suspension. A wall-clock step also cancels execution. Pausing the worker or the
invoking CLI does not pause the watchdog. Killing the invoking CLI closes its
control pipe, causing the watchdog to abort the worker.

The watchdog sends SIGKILL to the command's process group and waits for its
processes to exit. This includes background descendants, even when the
foreground command exits successfully. Linux seccomp prevents descendants from
escaping the group through session/group changes or a new PID/user namespace;
privilege-gaining exec is disabled. Commands that require these operations fail
inside the wrapper. This is process containment for cancellation, not a general
security sandbox. The initial implementation supports Linux x86_64 and aarch64;
other platforms refuse before starting the command. Tests currently run on
Linux x86_64.

Choose a margin that exceeds the operating environment's scheduling and abort
latency. Use this for local commands with abortable effects. Remote jobs,
external services, and operations whose effects cannot be stopped by terminating
the local process need an adapter with its own cancellation and completion
checks. The protocol's bounded watchdog/abort assumption still applies; a
suspended or failed watchdog itself cannot enforce a deadline.

This version chooses abort instead of automatic renewal. A separate renewal
does not update the token or extend the deadline of an already running command.
Run the next command with the newly captured sequence and deadline. Revocation
preserves the old exclusion window and blocks renewal; it does not shorten an
already captured deadline. Do not release a claim while its supervised command
is still running.

The command inherits its working directory, stdin, stdout, stderr, and existing
environment. Arguments after `--` are forwarded literally, without shell
interpolation. The wrapper supplies `GT_CLAIM_RUN_ID`, `GT_CLAIM_ID`,
`GT_CLAIM_LEASE_SEQ`, and `GT_CLAIM_EXPIRES_AT`, replacing stale inherited values.
In particular, `--run-id` reaches the existing pre-commit conflict hook.

A successful command returns 0. Deadline abort or a stale fence returns 4.
Cancellation, setup failures, and nonzero command exits return 1, with the
command's status reported on stderr; a child exit 3 cannot masquerade as a claim
conflict. The claim is retained after success or failure. Inspect partial work
before retrying, and release the claim when finished. Process termination does
not roll back files or completed effects.

## Pre-commit conflict check

```sh
gt claim hook install
gt claim check --staged
```

Installation is explicit. The installer follows Git's `core.hooksPath` and
linked-worktree hook resolution, publishes an executable hook atomically, and
refuses to overwrite any existing hook. Run `gt claim hook print` to obtain the
script for integration into an existing hook. Keep both checks' failure statuses.
The installed hook requires `gt` on `PATH`.

The hook invokes `gt claim check --staged`. It reads all changed paths from the
Git index, including deletions and both sides of renames, without shell expansion
or a 64-path batch cutoff. It honors Git's temporary index for partial commits.
Unstaged edits are outside this check. A successful staged check is silent; a
conflict returns 3 and names the blocked path, holder/run, remaining lease time,
quoted reason, and recovery commands. Git itself reports a hook refusal as a
failed commit, generally with exit 1. No network operation is involved.

This is the §17 conflict-only floor: unclaimed paths are permitted, and the
caller's own `(principal, device, run_id)` does not conflict. Agents sharing a
configured device **must use distinct run IDs** to be distinguishable. Set
`GT_CLAIM_RUN_ID` in the environment of both the acquiring agent and its
`git commit` processes; a `--run-id` argument on acquisition alone does not set
the hook's environment. An actor with the same configured device and an empty
run ID is indistinguishable from other callers using that same empty triple.

Passing this check does not reserve paths, validate a captured fencing token, or
supervise the duration of `git commit`. Use `gt claim exec` around an abortable
commit command to add token fencing and deadline supervision. The hook alone
does not grant permission to keep working beyond a lease deadline.

To explicitly bypass the advisory hook, use `git commit --no-verify`.
`gt claim check --staged --advisory-only` reports conflicts while returning 0;
configuration, I/O, and invalid-ledger errors still fail closed.

## Protocol and implementation status

Exit codes: **0** success, **1** usage/configuration/IO/invalid ledger,
**3** conflict (do not proceed), **4** stale, revoked, or expired lease,
**5** CAS contention (retry). Code **6** is reserved for future federated
operations held locally but not established. Refusals explain recovery.

The ledger uses signed `commit-tree` objects, one JSON blob per claim, and one
CAS on `refs/gitomi/claims/ledger`. CAS retries re-read state and revalidate with
25ms exponential full-jitter backoff, capped at 2s, for at most 12 attempts.
No claim tree is checked out and the Git index is untouched. Expiry uses the
holder's strict deadline and a 30s peer allowance for the default 15s maximum
clock skew. Revocation never makes a claim expire sooner.

Current state comes directly from the tip tree. This initial implementation also
authenticates the chain's signatures and diffs on every invocation; validation
cost therefore grows with history. A verified-head cache remains future work.
The local writer and validator support acquisition, renewal, release, and
expiry-based reaping. The validator checks renewal against both the previous and
new holder, immutable identity/acquisition fields, a strictly advancing sequence
and deadline, and the previous lease's expiry and revocation. Administrative
modifications still fail closed.

Administrative revocation, compaction, federation, AGENTS template installation,
and MCP exposure remain later phases. `check` is a point-in-time advisory conflict query, not a fenced
operation or permission to continue beyond a lease deadline. Stop work before
your lease expires; only commands explicitly launched through `exec` receive its
supervision.

The product decisions for the remaining work are recorded in
[ADR 002: Claims With Optional Orchestration](../spec/ADR/002_CLAIMS_WITH_OPTIONAL_ORCHESTRATION.md).
Coordination works without an orchestrator. Claim administration will belong to
maintainers and owners, with explicit repository or worker-run delegations.
Initial compaction will re-root only an empty, verified ledger through CAS;
active claims keep their authenticated history. Local watchdog supervision is
implemented. The administrative/compaction normative amendments, authorization
evidence, and corresponding CLI features are still pending.

Tests include signed acquire/conflict/release, readers, separate signers/runs,
waiting, malformed and unauthorized ledger changes, and races forced to prepare
against both an absent ref and an existing tip. The races require exactly one
success and one conflict, and separately test contention exhaustion.

Phase 2 tests additionally cover bounded peer summaries, safe recovery commands,
staged versus unstaged changes, rename sources and destinations, deletions,
unusual filenames, more than 64 staged files, partial commits, initial commits,
linked worktrees, hook preservation, and explicit bypass.

Lifecycle tests cover signed renewal and forged renewal rejection, stale tokens
and runs, the immutable acquisition time and lifetime bound, expiry during
signing, live revocations retaining exclusion, foreign expiry collection, the
skew boundary and action budget, and simultaneous renewal with one captured
token (exactly one success and one stale refusal).

Execution tests cover captured-token refusals, read/write mode checks, literal
arguments and environment propagation, a real signed commit with the hook,
paused workers and callers, killed callers, cancellation, background cleanup,
session escape refusal, and an external renewal that cannot extend an old
operation's captured deadline. They check that workers and descendants are
reaped before the holder deadline and that the ledger remains unchanged.
