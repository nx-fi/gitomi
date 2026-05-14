# Gitomi

A local-first, Git-native forge that layers issues, pull requests, projects,
milestones, ACLs, and workflow execution over a standard Git repository.

Gitomi stores all social and automation state as signed, append-only event
commits in ordinary Git refs — no server, no database, no custom transport.
Everything syncs with `git fetch` and `git push`.

## Architecture

- **Data Plane** — standard Git branches, tags, trees, and blobs for source code.
- **Control Plane** — a distributed event DAG in `refs/gitomi/inbox/*`, signed
  per-device and reduced into current state by deterministic CRDT-style reducers.

## CLI

The `gt` command-line client is written in Zig. See [`cli/README.md`](cli/README.md)
for build instructions and the full command reference.

```sh
cd cli && zig build
./zig-out/bin/gt --help
```

## Specification

The normative design lives in [`spec/`](spec/):

| Document | Contents |
|----------|----------|
| [01_PRODUCT.md](spec/01_PRODUCT.md) | Event model, object types, reducers, sync, actions engine |
| [02_REFS.md](spec/02_REFS.md) | Ref namespaces, commit format, validation pipeline |
| [03_RBAC.md](spec/03_RBAC.md) | Roles, permissions, bootstrap trust, ACL & identity reducers |

## License

[MIT](LICENSE)
