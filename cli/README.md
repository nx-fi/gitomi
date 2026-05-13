# Gitomi CLI

`gt` is the Zig command line client for Gitomi.

Build:

```sh
zig build
```

Run from this package:

```sh
zig build run -- --help
```

Installed binary name:

```sh
zig build install
./zig-out/bin/gt --help
```

Implemented commands:

```text
gt init [--principal ID] [--device ID] [--repo-id UUID] [--force]
gt status
gt fsck
gt index rebuild|status
gt refs
gt events list [--json] [--limit N] [--ref REF]
gt issue open --title TITLE [--body BODY] [--label LABEL] [--assignee PRINCIPAL]
gt sync [--remote REMOTE] [--pull-only|--push-only]
```

`gt issue open` writes a signed Git commit to the configured inbox ref under
`refs/gitomi/inbox/<principal>/<device>`. Configure native Git commit signing
before using it, for example SSH signing via `gpg.format=ssh`.

`gt sync` fetches remote inbox refs into `refs/gitomi/staging/<remote>/inbox/*`
first, then admits only new or fast-forward refs into `refs/gitomi/inbox/*`
after checking the event commit chain, empty-tree rule, native Git signature,
and v1 JSON envelope. Diverged or stale staged refs are left staged for
inspection instead of clobbering local authoritative refs.

`gt fsck` verifies authoritative inbox refs for ref-safe names, empty-tree event
commits, native Git signatures, v1 event envelopes, matching repo IDs, unique
`(principal, device, seq)` tuples, and first-parent inbox-chain shape.

`gt index rebuild` writes a disposable event projection to
`.git/gitomi/index.jsonl` with ref heads in `.git/gitomi/index.refs`.
`gt events list` and `gt status` rebuild it automatically when inbox heads
change, then read from the index instead of running `git show` for every event.
