# Zig Reactor — Chemske

Front: direct

**Status: milestone 2 — tags and all four users/auth routes. Not submission-ready.**

I am building a Conduit implementation for the Multicore Server Challenge, targeting the highest sustainable official score. My development environment is native macOS on Apple Silicon. I keep the toolchain, database, caches and generated files within one project workspace wherever the tools allow it.

The first implementation is a small event-driven Zig server using the official PostgreSQL client library in non-blocking mode. It serves tags, registration, login and current-user reads/updates directly over HTTP/1.1. Query batching and the remaining endpoints are planned, not implemented.

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
```

Each Python check creates and removes a private database copy and launches its own server. Milestone 1 covers tags/protocol regressions. Milestone 2 runs the unchanged upstream suite, requires all 50 users/auth steps to pass, and adds focused checks for commit visibility, token validation, bcrypt compatibility, concurrency and failure recovery. It also runs the unmodified Go reference briefly for bcrypt comparisons. All test binaries, logs and transcripts stay under work/.

## Design notes

- [Research and selection](docs/RESEARCH.md): evidence, alternatives, uncertainties and the case for this architecture.
- [Competitor source review](docs/COMPETITOR_REVIEW.md): leading implementations, reproduced parser observations and specific improvement opportunities.
- [Architecture](docs/ARCHITECTURE.md): ownership, scheduling, batching and correctness boundaries.
- [Development and cleanup](docs/DEVELOPMENT.md): native Mac setup policy, milestone gates and removal inventory.

## Current validation

The unmodified Go example passed all 197 conformance steps against this native PostgreSQL 18.6 environment. That validates the environment; it is not a conformance pass for this Zig server.

The Zig implementation passes all 50 users/auth steps from the unchanged upstream suite, six unit checks, the 11 tags regression scenarios and 13 auth scenarios. The full upstream run currently reports 137 steps, 61 passed and 76 failed, then stops because later endpoints are unimplemented. This is a checkpoint, not a full conformance pass.

The auth checks include cross-verification with the unmodified Go reference for 72-byte, UTF-8 and embedded-NUL passwords. Zig 0.17 renders bcrypt as $2b$ and compares that version marker during verification; my adapter accepts the seed's corrected $2a$ format by normalizing only the marker before performing bcrypt. New passwords over 72 bytes are rejected; login verification follows Go's bcrypt truncation behaviour. Every login to an existing account still performs bcrypt verification, and changing the stored hash affects the next attempt.

A blocked update is tested to withhold success until the lock is released and the write commits. A separate database session confirms visibility after success. Forty concurrent logins exercise bounded overload while tags requests continue; rejected password jobs return 503 and are counted. These are correctness checks, not capacity measurements.

The Linux source path passes object-only cross-compilation; no linked Linux server has been run. There are no official scores.

Current limits are deliberate: one database connection, 256 client slots, two bcrypt workers and at most 16 outstanding password jobs. Headers are limited to 16 KiB, bodies to 64 KiB and total buffered request data to 84 KiB. Chunked bodies are rejected and the connection closed. Idle clients have a 70-second timeout; active requests and database work have deadlines. A query error is drained and the connection can be reused; a lost database connection puts the service into 503 mode until restart. Profiles/follows, articles, comments, favourites, reconnects, batching and the Ubuntu install script remain future work.

## Working principles

I preserve the challenge's schema, workload and conformance suite. I verify every token and every login, commit writes before replying, and retain no response or query-result cache across requests. I document measurements with their hardware, data, commit and duration. Any reused code keeps its original attribution and licence.
