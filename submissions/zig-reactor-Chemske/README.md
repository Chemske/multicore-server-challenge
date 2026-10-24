# Zig Reactor — Chemske

Front: direct

**Status: milestone 1 — native database setup and a working tags endpoint. Not submission-ready.**

I am building a Conduit implementation for the Multicore Server Challenge, targeting the highest sustainable official score. My development environment is native macOS on Apple Silicon. I keep the toolchain, database, caches and generated files within one project workspace wherever the tools allow it.

The first implementation is a small event-driven Zig server using the official PostgreSQL client library in non-blocking mode. It serves GET /api/tags directly over HTTP/1.1. Query batching and the remaining endpoints are planned, not implemented.

The central idea is simple: **make each request create less work for the whole machine, especially PostgreSQL.** More threads are not automatically more useful when the application and database share eight CPUs.

## Proposed stack

| Component | Choice |
|---|---|
| Application | Zig 0.17.0 |
| Networking | Small Zig reactor; kqueue on macOS, epoll on Linux |
| HTTP parsing | Vendored picohttpparser at 465a7ff09fbd3432fe56c673451f5460154d1f07 |
| PostgreSQL | PostgreSQL/libpq 18.6; asynchronous single-query path implemented, pipeline mode planned |
| Authentication | HS256 and bcrypt cost 10 planned; no auth endpoints implemented yet |
| Deployment | Direct HTTP; official Ubuntu 24.04 x86_64 runtime contract |

The application and scheduling logic are Zig. libpq and picohttpparser are C libraries, not separate services or development applications. Source pins and hashes are documented in [vendor/README.md](vendor/README.md). PostgreSQL is built locally from its official checked source archive.

## Run the first milestone on macOS

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
```

The Python check creates and removes a private database copy, launches its own server and exercises concurrent requests, keep-alive, framing, fresh database reads and failures.

## Design notes

- [Research and selection](docs/RESEARCH.md): evidence, alternatives, uncertainties and the case for this architecture.
- [Competitor source review](docs/COMPETITOR_REVIEW.md): leading implementations, reproduced parser observations and specific improvement opportunities.
- [Architecture](docs/ARCHITECTURE.md): ownership, scheduling, batching and correctness boundaries.
- [Development and cleanup](docs/DEVELOPMENT.md): native Mac setup policy, milestone gates and removal inventory.

## Current validation

The unmodified Go example passed all 197 conformance steps against this native PostgreSQL 18.6 environment. That validates the environment; it is not a conformance pass for this Zig server.

The Zig milestone passed protocol unit checks and 11 integration scenarios, including 64 requests across 16 simultaneous keep-alive clients. The Linux source path also passed an object-only cross-compilation check; no linked Linux server has been run. There are no capacity benchmarks or official scores.

Current limits are deliberate: one database connection, 256 client slots, bounded request/response buffers, a 70-second idle timeout and request/query deadlines. Only GET /api/tags is implemented. Request bodies are rejected and connections closed. A query error is drained and the connection can be reused; a lost database connection puts the service into 503 mode until restart. Authentication, writes, reconnects, batching and the Ubuntu install script remain future work.

## Working principles

I preserve the challenge's schema, workload and conformance suite. I verify every token and every login, commit writes before replying, and retain no response or query-result cache across requests. I document measurements with their hardware, data, commit and duration. Any reused code keeps its original attribution and licence.
