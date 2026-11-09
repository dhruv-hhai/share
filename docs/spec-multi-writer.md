# Spec: multiple writers, leases, locks and a ledger

[← README](../README.md) · status: proposed 2026-11-09, nothing built

## Why

Share keeps one folder converged across machines. It does not yet handle
several **processes on one machine**, such as agent sessions in one working
tree. They overwrite each other silently: the scanner sees one new version,
attributed to the replica, and the earlier write is lost without siblings.
Lattice, an agent setup with leases, ephemeral workers and a fix-forward
integrator, needs one mechanism for both cases. Two sessions overlapping and
two machines overlapping should be the same event, and the same `.sharemerge`
strategies, collision log and history should handle both.

Goals:

1. A concurrent write by another process becomes causal siblings, never a lost update.
2. Leases and locks work across processes and across machines.
3. An append-only, replicated ledger of state transitions, so a session or a
   machine can die and another can resume from the ledger.
4. The per-tool-call cost for hooks stays under 5 ms.

Non-goals: Byzantine fault tolerance, consensus with fewer than three
replicas, and replacing backups. The ledger records state transitions;
Borg keeps the bytes.

## Terms

- **Replica:** one synced folder on one machine, as today, with its own replica ID (`rid`).
- **Writer:** `rid/<name>`, a process that edits the tree, such as an agent
  session. Writes with no declared writer are attributed to `rid/-`.
- **Base:** the version a writer last saw for a path, by hash or stat tuple.
- **Lease:** a claim by one writer on a set of path globs, with a TTL and a
  liveness test. Leases are advisory unless a hook enforces them.
- **Lock:** mutual exclusion on a name, held for the length of one command.
- **Ledger:** the union of per-writer, hash-chained, append-only entry chains.

## Contracts

Two schemas are fixed from the first release that writes them. Everything else
in this spec is a projection of them and may change layout freely.

### A. Envelope (one payload)

A tar archive, as today, with members:

| member | content |
| --- | --- |
| `version` | the single line `2` |
| `replica` | sender `rid` |
| `manifest` | 4-column TSV `path hash parent vector` (unchanged) |
| `features` | one feature word per line, `#` comments (parsed like `.shareignore`) |
| `critical` | subset of `features` the receiver must support or refuse the payload |
| `blobs/<sha256>` | content bytes, hash-verified |
| `base/<sha256>` | retained merge bases |
| `ledger/<rid>/<writer>.log` | ledger chains (only when the peer advertises `ledger`) |

Rules: unknown members and unknown non-critical features are skipped with a
log line, never refused; a `critical` feature the receiver lacks refuses the
whole payload loudly. Feature words so far: `writer`, `ledger`.

### B. Ledger entry (one TSV line)

```
id  prev  hlc  writer  kind  subject  data...
```

- `id`: sha256 (hex) of the line from `prev` to the end, computed with the
  repo's `openssl dgst -sha256` idiom. The bytes are the canonical form.
- `prev`: `id` of this writer's previous entry, `-` for the first.
- `hlc`: `%010d%06d` (unix seconds, per-writer counter), fixed width so
  `LC_ALL=C sort` orders it. Ties break on `writer`.
- `writer`: `rid/<name>`; `<name>` matches `[A-Za-z0-9_.-]+`, default `-`.
- `kind`: a word; unknown kinds are stored, replicated and replayed unchanged.
- `subject`: typed name — `path:<path>`, `glob:<glob>`, `lock:<name>`,
  `role:<name>`, or `-`.
- `data...`: kind-specific extra columns (tabs and newlines cannot occur in
  paths, see `safe_path`).

| kind | subject | data columns |
| --- | --- | --- |
| `version` | `path:P` | `hash parent vector base` |
| `lease-claim` | `glob:G` (one entry per glob) | `expires pid ttl` |
| `lease-renew` | `glob:G` | `expires` |
| `lease-release` | `glob:G` | `-` |
| `lease-lost` | `glob:G` | `winner-id` |
| `lock` / `unlock` | `lock:NAME` | `pid expires` |
| `collision` / `conflict` | `path:P` | `hashes [holder]` |
| `snapshot` | `-` | `name:sha256,...` of each projection |

Vector grammar (unchanged): `key:n,key:n`, `LC_ALL=C` sorted; `key` is a
`rid` or an ephemeral `rid~<name>`.

### Projections (derived, free to change)

Each is `LC_ALL=C sort -u ledger/*/*.log | awk`, written as `<file>.new` then
`mv`: the manifest (`version` entries through `sync-merge.awk`), `history`,
`.share/leases.idx`, `.share/collisions`, `.share/locks/`. Hooks read one
projection with the `path_entries` idiom (`awk '$1==ENVIRON[...]'`).

### Shell API (lib/sync-ledger.sh)

`ledger_append WRITER KIND SUBJECT [DATA...]` (prints id), `ledger_hlc`,
`ledger_lines [KIND]` (sorted union), `ledger_verify`,
`ledger_accept LOCAL INCOMING` (prefix-extends or forks to
`<writer>.fork-<8 hash>.log`), `project_leases`. Hook commands never call
these; they append one line to `.share/writers/<writer>.q`
(`time op path-or-kind rest...`, `op` in `s w l`) and the daemon drains it.

## 1. Writer identity

- `share sync ... --writer NAME`, and the `SHARE_WRITER` env var, set the
  writer for `seen`, `wrote`, `lease`, `lock` and `log` calls.
- The manifest record stays four columns (2.1 peers refuse any other width,
  `lib/sync-payload.sh` `NF!=4`). The writer lives in the ledger `version`
  entry for that version, and `history` lines gain a fifth column `writer`.
  Writer is metadata only: it is **not** part of vector dominance.
- `share sync history --writer W` and `--path P` filter by writer and path, which gives blame.

## 2. Bases: seen / wrote

Hooks report what a writer read and wrote:

```sh
share seen  <path>... [--writer W]   # on read: record the current local head as W's base
share wrote <path>... [--writer W]   # after a write: version now, with W's base as parent
```

- `seen` appends `(time, writer, path, stat tuple)` to
  `.share/writers/<writer>.q` and returns at once. The daemon resolves stat
  tuples to hashes from its cache. It never hashes on the caller's path.
- `wrote` appends the same queue line with `op=w`. The daemon versions the
  path in its next pass, ahead of the scanner, and does so immediately when it's idle.
- **Concurrency rule:** writer W wrote path P with base B. If the local head
  H of P is not B (another writer versioned P after W last saw it), W's
  content and H are **siblings with parent B**. Both versions survive, and
  the path's `.sharemerge` strategy resolves them: `diff3` and `json-merge`
  merge, `lease` records a collision, `conflict-copies` keeps both.
- **Encoding (recommended):** vectors stay per replica. A detected local
  sibling gets an ephemeral vector key `rid~W` for that one version, so the
  existing dominance rules apply unchanged. The merge version that resolves
  it dominates both keys, so dead keys stop mattering. Keys are bounded by
  the number of detected conflicts, not by the number of writers.
- If a write has no declared path (for example a shell command), the scanner
  versions it as today, attributed to `rid/-`.
- `share seen` / `share wrote` with no daemon running append to the queue
  anyway, and the next daemon start drains it.

## 3. Leases

```sh
share lease claim   <glob>... --ttl 30m [--writer W] [--pid PID]  # exit 3 if held by another live writer
share lease renew   [--writer W]
share lease release [<glob>...] [--writer W]
share lease check   <path>... [--writer W]   # exit 0 free or own, 3 held (stdout: the holder's lease entry line)
share lease list                    # TSV, one live lease per line
```

- Leases are ledger entries (`claim`, `renew`, `release`); see section 5. The
  current lease table is a projection, cached in `.share/leases.idx`, and
  `check` reads only that index.
- **Liveness:** a lease is live while its TTL has not expired **and**, on the
  holder's own replica, its `--pid` is alive. This uses the same rule as the
  sync lock since #9: never break a lock by age alone while its holder is alive.
  A dead PID frees the lease at once on that replica.
- **Cross-machine races:** two replicas can claim overlapping globs during
  the sync delay. On merge, the earliest claim wins, by (HLC, writer). The
  loser gets a `lease-lost` ledger entry and a `history` `L` event, and any
  writes it made under the lease become collisions for the integrator. With
  three or more replicas, an optional `--quorum` waits for a majority to
  acknowledge before `claim` returns.
- The `.sharemerge` `lease` strategy keeps its meaning (concurrent versions
  of a lease path are a violation) and now also names the holder.

## 4. Locks

```sh
share lock <name> [--ttl 10m] [--wait 60s] -- <cmd>...
```

- **Same host:** an exclusive `flock(1)` on `.share/locks/<name>` (util-linux on
  Linux, the `flock` formula on macOS). The kernel releases it when the holder
  exits or is killed, so there is no stale-lock breaking; `--ttl` is recorded,
  not enforced. Ledger appends take the same kind of lock per writer chain.
  `mkdir` locks are not used: concurrent `mkdir` was seen to succeed twice on one
  Linux CI kernel.
- **Across machines:** the lock is a lease on the name `lock:<name>`, granted
  by the **lock authority**, which is `--role a` unless configured otherwise.
  A non-authority replica asks the authority over the existing transport; if
  the authority is unreachable, it fails with exit 4, never granting itself.
  Examples: deploys, `pnpm install`, index regeneration, service restarts.

## 5. Ledger

```sh
share log append <kind> <subject> [data...]   # queued onto this writer's chain; prints its hlc
share log tail [--since ID] [--kind K]        # TSV entry lines
share log watch [--since ID]      # follows; TSV entry lines
share log verify                  # hash chains, gaps, forks
```

- **Storage:** one file per writer, `.share/ledger/<rid>/<writer>.log`,
  append-only. Each entry is one TSV line (see Contracts): no JSON, no jq.
- **Replication:** ledger files sync with the folder, but only by appending.
  A peer accepts a chain only if it extends what it already holds. A fork
  (two different entries with the same `prev`) is kept, and `verify` reports it.
- **Order:** sort the union of all chains by (HLC, writer). Hybrid logical
  clocks keep this order consistent with causality despite clock skew.
- **Kinds owned by share:** `version` (path, hash, parent, writer, base),
  `lease-claim`, `lease-renew`, `lease-release`, `lease-lost`, `lock`,
  `unlock`, `conflict`, `collision` and `snapshot`. Other kinds are opaque;
  Lattice uses them for session and work-item state.
- **Compaction:** a `snapshot` entry records the digest of every projection,
  such as the leases and open work items. Segments older than the newest
  snapshot that every replica has acknowledged move to `.share/ledger/archive/`.
  `verify` checks a snapshot against a replay.
- `history` stays as is, a human-readable log, and becomes derivable from the ledger.

## 6. Change feed, barrier and restore

- `share log watch --kind version` is the change feed for local writes from
  other writers and for incoming remote ones, with writer, op, path, version
  and base. Consumers keep their own cursor.
- **Hook:** `${XDG_CONFIG_HOME:-~/.config}/share/hooks/applied` is run,
  detached, with the paths of every applied remote batch. It is not synced,
  just like the merge drivers.
- `share wait --version <hash> [--path P] [--peer R] [--timeout]` exits 0
  once the peer reports that version or a later one, which serves as a barrier
  before a check runs on another machine.
- `share restore <path> --version <hash> | --at <time>` re-creates content
  from retained blobs when they still exist, and otherwise says to use the
  backup. It writes a new version and never rewrites history.

## 7. A named supervisor lease (HA)

Nothing new is needed beyond leases: a role such as Lattice's root
supervisor is a lease on `role:supervisor` with a short TTL that is renewed
on every pass. Eligible replicas try `claim` when the lease expires, and the
earliest claim wins (or `--quorum` with three replicas). A replica that
should only *watch*, like a laptop, runs `share lease list` and alerts when
the lease is stale, without claiming it.

## Performance budget

`seen`, `wrote`, `lease check` and `log append` run on every agent tool call.
Each must:

- append one line or read one index;
- run without starting the daemon, network calls, hashing large files or taking the sync lock;
- finish in under 5 ms at p50 on the reference host.

All merging, hashing and replication happens in the daemon.

## Compatibility

- 2.1 peers refuse unknown payload members, a `version` file other than `2`
  and any manifest row that is not four columns. So phase 0 ships a 2.2 that
  only *receives* leniently (unknown members and non-critical features are
  skipped, `features`/`critical` are read) while still sending the 2.1
  envelope. New members start shipping once both peers advertise them.
- `rid~W` vector keys are ordinary vector keys to a 2.1 peer. A mixed pair
  converges, but the older side does not attribute writers.
- `ledger/` members are sent only to peers that advertise `ledger`.

## Phases and acceptance tests

| Phase | Build | Test |
| --- | --- | --- |
| 0 | Lenient receive: skip unknown members, read `features`/`critical`; send `features` | A 2.2 peer accepts a payload with an unknown member and refuses one whose `critical` names a feature it lacks. `test/sync-files` |
| 1 | `--writer`, the history writer column, `seen` and `wrote` queues | Two writers edit one file from one base: both versions survive and `diff3` merges them. `test/sync-writers` |
| 2 | Leases: claim, renew, release, check, list, PID liveness | A dead PID frees the lease at once. A live holder past its TTL is kept with `renew`. `check` p50 under 5 ms |
| 3 | Ledger: append, tail, watch, verify; leases moved onto it | Two replicas claim one glob while partitioned: after merge, one winner and one `lease-lost` |
| 4 | Locks, the lock authority, the `applied` hook, `wait` | Concurrent `share lock x -- sleep` on two hosts never overlap. `wait` returns after the peer applies |
| 5 | Snapshots and compaction, `restore`, `--quorum` | `verify` replays from a snapshot. A 3-replica quorum claim survives one replica down |

## Open questions

- Should `seen` hash small files immediately? That costs more but makes the
  base exact if a file is rewritten twice within one second, where a stat
  tuple can't tell the versions apart.
- How much of the cross-machine lock protocol fits on the croc transport? A
  long-lived connection to the authority may be needed for sub-second grants.
- How long are archived ledger segments kept, and are they kept in Borg only?
