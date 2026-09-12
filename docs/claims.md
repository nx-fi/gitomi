# Local path claims (phase 1)

`gt claim` implements the local acquisition product from
[`spec/08_CLAIMS.md`](../spec/08_CLAIMS.md). Initialize Gitomi with `gt init`
and configure commit signing and verification as for other signed Gitomi writes.
The signing key must belong to an accepted device binding.

```sh
git config gitomi.claims.mode single-store
gt claim acquire 'src/auth/**' --ttl 15m --reason 'refactoring token validation' --json
gt claim check 'src/auth/**'
gt claim ls --all
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

Renewal, watchdog-backed gated operations, hooks, `gt peers`, automatic reaping,
compaction, federation, AGENTS template installation, and MCP exposure remain
later phases. `check` is a point-in-time advisory conflict query, not a fenced
operation or permission to continue beyond a lease deadline. Stop work before
your lease expires; this phase does not supervise a running editor or command.

Tests include signed acquire/conflict/release, readers, separate signers/runs,
waiting, malformed and unauthorized ledger changes, and races forced to prepare
against both an absent ref and an existing tip. The races require exactly one
success and one conflict, and separately test contention exhaustion.
