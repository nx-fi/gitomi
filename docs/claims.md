# Local path claims and commit checks (phases 1–2)

`gt claim` implements local acquisition and the pre-commit conflict check from
[`spec/08_CLAIMS.md`](../spec/08_CLAIMS.md). Initialize Gitomi with `gt init`
and configure commit signing and verification as for other signed Gitomi writes.
The signing key must belong to an accepted device binding.

```sh
git config gitomi.claims.mode single-store
gt claim acquire 'src/auth/**' --ttl 15m --reason 'refactoring token validation' --json
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

`gt peers [paths...]` shows one line per relevant live claim held by another
holder/run, including shared readers. It displays at most 50 claims, summarizes
paths and reasons, and reports omitted claims. It displays claim metadata, never
session transcripts. `--run-id UUID` or `GT_CLAIM_RUN_ID` identifies your run.

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
supervise the duration of `git commit`. Token fencing and watchdog-backed
execution remain part of lifecycle support. In particular, it does not grant
permission to keep working beyond a lease deadline.

To explicitly bypass the advisory hook, use `git commit --no-verify`.
`gt claim check --staged --advisory-only` reports conflicts while returning 0;
configuration, I/O, and invalid-ledger errors still fail closed.

## Protocol and implementation status

Exit codes: **0** success, **1** usage/configuration/IO/invalid ledger,
**3** conflict (do not proceed), **4** lease expired before confirmation,
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
The local writer supports acquisition and release, and the validator understands
expiry-based reap deltas. Other lifecycle deltas fail closed in this phase.

Renewal, watchdog-backed gated operations, automatic reaping,
compaction, federation, AGENTS template installation, and MCP exposure remain
later phases. `check` is a point-in-time advisory conflict query, not a fenced
operation or permission to continue beyond a lease deadline. Stop work before
your lease expires; this phase does not supervise a running editor or command.

Tests include signed acquire/conflict/release, readers, separate signers/runs,
waiting, malformed and unauthorized ledger changes, and races forced to prepare
against both an absent ref and an existing tip. The races require exactly one
success and one conflict, and separately test contention exhaustion.

Phase 2 tests additionally cover bounded peer summaries, safe recovery commands,
staged versus unstaged changes, rename sources and destinations, deletions,
unusual filenames, more than 64 staged files, partial commits, initial commits,
linked worktrees, hook preservation, and explicit bypass.
