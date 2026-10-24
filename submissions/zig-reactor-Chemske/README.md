# Zig Reactor — Chemske

Front: direct

**Status: milestone 4 — article/feed reads, tags, users/auth and profiles/follows. Not submission-ready.**

I am building a Conduit implementation for the Multicore Server Challenge, targeting the highest sustainable official score. My development environment is native macOS on Apple Silicon. I keep the toolchain, database, caches and generated files within one project workspace wherever the tools allow it.

The first implementation is a small event-driven Zig server using the official PostgreSQL client library in non-blocking mode. It serves tags, registration, login, current-user reads/updates, profiles/follows, article lists, the personal feed and single-article reads directly over HTTP/1.1. Query batching and the remaining endpoints are planned, not implemented.

The central idea is simple: **make each request create less work for the whole machine, especially PostgreSQL.** More threads are not automatically more useful when the application and database share eight CPUs.

## Proposed stack

| Component | Choice |
|---|---|
| Application | Zig 0.17.0 |
| Networking | Small Zig reactor; kqueue on macOS, epoll on Linux |
| HTTP parsing | Vendored picohttpparser at 465a7ff09fbd3432fe56c673451f5460154d1f07 |
| PostgreSQL | PostgreSQL/libpq 18.6; asynchronous single-query path implemented, pipeline mode planned |
| Authentication | HS256 on every authenticated request; bcrypt cost 10 in two bounded workers |
| Deployment | Direct HTTP; official Ubuntu 24.04 x86_64 runtime contract |

The application and scheduling logic are Zig. libpq and picohttpparser are C libraries, not separate services or development applications. Source pins and hashes are documented in [vendor/README.md](vendor/README.md). PostgreSQL is built locally from its official checked source archive.

## Run locally on macOS

From this submission directory, in Bash or Zsh:

```sh
source dev/env.sh
bash dev/setup-postgres.sh
bash dev/database.sh start
bash dev/database.sh seed
bash build.sh
bash start.sh
```

In another terminal, GET http://127.0.0.1:3000/api/tags. The environment defaults to the disposable interactive database conduit_local on authenticated loopback port 55432. The conduit_dev seed remains a template and must not have a server connected while tests copy it.

Stop the server with Ctrl+C, then stop the dedicated database with `bash dev/database.sh stop`. Nothing is registered to start automatically with macOS.

For the focused checks:

```sh
source dev/env.sh
zig build test -Dpg-root="$PGROOT"
python3 tests/milestone1.py
python3 tests/milestone2.py
python3 tests/milestone3.py
python3 tests/milestone4.py
```

Each Python check creates and removes a private database copy and launches its own server. Milestone 1 covers tags/protocol regressions. Milestone 2 runs the unchanged upstream suite, requires all 50 users/auth steps to pass, and adds focused checks for commit visibility, token validation, bcrypt compatibility, concurrency and failure recovery. It also runs the unmodified Go reference briefly for bcrypt comparisons. Milestone 3 requires all 16 profile steps reached before the missing comment-create route to pass and compares their normalized responses with a fresh full run of the unchanged Go reference. It adds targeted profile, viewer-isolation, path, contention, rollback and commit-failure checks. Milestone 4 compares all 119 upstream steps before favourite writes, including 51 article/feed read steps, and exercises extra pagination, serialization, concurrency and two-stage query failures. Shared Python helpers manage disposable servers and reference transcripts. All test binaries, logs and transcripts stay under work/.

## Design notes

- [Research and selection](docs/RESEARCH.md): evidence, alternatives, uncertainties and the case for this architecture.
- [Competitor source review](docs/COMPETITOR_REVIEW.md): leading implementations, reproduced parser observations and specific improvement opportunities.
- [Architecture](docs/ARCHITECTURE.md): ownership, scheduling, batching and correctness boundaries.
- [Development and cleanup](docs/DEVELOPMENT.md): native Mac setup policy, milestone gates and removal inventory.

## Current validation

The unmodified Go example passed all 197 conformance steps against this native PostgreSQL 18.6 environment. That validates the environment; it is not a conformance pass for this Zig server.

The Zig implementation passes all 119 unchanged upstream steps before favourite writes, including 50 users/auth, 16 profile and 51 article/feed steps. All 119 normalized responses match the unchanged Go reference. Eleven unit checks, 11 tags scenarios, 13 auth scenarios, 15 profile scenarios and 15 article/feed scenarios pass.

The full Zig run currently reports 141 steps, 123 passed and 18 failed, then stops at the missing comment-create route. Remaining failures involve unimplemented writes/comments and later reads that depend on those writes. Two profile calls later in the script remain unreached. This is a checkpoint, not a full conformance pass.

The auth checks include cross-verification with the unmodified Go reference for 72-byte, UTF-8 and embedded-NUL passwords. Zig 0.17 renders bcrypt as $2b$ and compares that version marker during verification; my adapter accepts the seed's corrected $2a$ format by normalizing only the marker before performing bcrypt. New passwords over 72 bytes are rejected; login verification follows Go's bcrypt truncation behaviour. Every login to an existing account still performs bcrypt verification, and changing the stored hash affects the next attempt.

A blocked update is tested to withhold success until the lock is released and the write commits. A separate database session confirms visibility after success. Forty concurrent logins exercise bounded overload while tags requests continue; rejected password jobs return 503 and are counted. These are correctness checks, not capacity measurements.

Profile reads query the current relationship for the requesting viewer. Follow and unfollow each use one parameterized statement with a target lookup and data-modifying CTE. Their responses wait for transaction completion, including deferred commit errors. Repeated operations keep the requested following state. Tests cover external changes, concurrent duplicates, blocked writes and a deferred commit failure that rolls back the inserted relation.

All 16 reached normalized profile responses match the unchanged Go reference, which passes all 197 steps on a separate fresh clone. One deliberate difference outside that transcript follows the specification: a present empty Authorization header returns 401. The Go reference treats that header as absent. Dynamic usernames are decoded once as path segments, preserving literal plus signs and encoded separators.

Article lists select page IDs in descending order before enrichment, then run a separate capped count, preserving the reference's statement order and snapshot behaviour. Counts stop at 1,000 without limiting which pages are accessible. Tag, author and favourited filters have the required precedence; unknown filters produce empty lists. Every request computes viewer-dependent flags from the database. Single articles include body; list objects omit it. Zig serializes JSON and decodes PostgreSQL text arrays; SQL formats UTC timestamps with three truncated fractional digits.

The read tests cover empty pages that still need a count, duplicate and encoded query parameters, escaped tag names, timestamps before 1970, 96 concurrent reads, failed page/count queries and slow/disconnected readers. Valid large feed offsets return empty pages with the correct count; the reference's int32 arithmetic returns 500 for a tested valid offset. My feed query uses overflow-safe arithmetic. No speedup is claimed from these correctness checks.

The Linux source path passes object-only cross-compilation; no linked Linux server has been run. There are no official scores.

Current limits are deliberate: one database connection, 256 client slots, two bcrypt workers and at most 16 outstanding password jobs. Headers are limited to 16 KiB, bodies to 64 KiB and total buffered request data to 84 KiB. Chunked bodies are rejected and the connection closed. Idle clients have a 70-second timeout; active requests and database work have deadlines. A query error is drained and the connection can be reused; a lost database connection puts the service into 503 mode until restart. Article writes, comments, favourite writes, reconnects, batching and the Ubuntu install script remain future work. Article reads have a 4 MiB retained-field and serialized-response bound; larger results return 503.

## Working principles

I preserve the challenge's schema, workload and conformance suite. I verify every token and every login, commit writes before replying, and retain no response or query-result cache across requests. I document measurements with their hardware, data, commit and duration. Any reused code keeps its original attribution and licence.
