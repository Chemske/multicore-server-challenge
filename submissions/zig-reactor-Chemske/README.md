# Zig Reactor — Chemske

Front: direct

**Status: milestone 6 — bounded database concurrency and automatic recovery; 197/197 development-seed conformance checks pass. Not submission-ready.**

I am building a Conduit implementation for the Multicore Server Challenge, targeting the highest sustainable official score. My development environment is native macOS on Apple Silicon. I keep the toolchain, database, caches and generated files within one project workspace wherever the tools allow it.

The implementation is a small event-driven Zig server using the official PostgreSQL client library in non-blocking mode. It serves the complete Conduit API directly over HTTP/1.1, including article writes, favourites and comments. Four database owners progress independently and recover failed connections without replaying requests. Nineteen fixed queries on the original API path are prepared per connection; the article/comment operation state machine still uses its original parameterized statements. Query batching and clean Linux installation remain planned.

The central idea is simple: **make each request create less work for the whole machine, especially PostgreSQL.** More threads are not automatically more useful when the application and database share eight CPUs.

## Proposed stack

| Component | Choice |
|---|---|
| Application | Zig 0.17.0 |
| Networking | Small Zig reactor; kqueue on macOS, epoll on Linux |
| HTTP parsing | Vendored picohttpparser at 465a7ff09fbd3432fe56c673451f5460154d1f07 |
| PostgreSQL | PostgreSQL/libpq 18.6; four owned non-blocking connections, named prepared queries and recovery; pipeline mode planned |
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
python3 tests/milestone5.py
python3 tests/recovery.py
```

Each Python check creates and removes private database copies and launches its own server. Milestones 1–4 cover protocol behaviour, auth, profiles and article/feed reads. The profile gate checks every profile step reached by the current suite, now all 18. Milestone 5 requires the complete unchanged suite to pass and compares all 197 normalized responses with the unchanged Go reference. It also exercises failed transactions, committed writes, ownership and concurrent clients. Shared helpers use only Python's standard library. Test binaries, logs and transcripts stay under work/.

The upstream runner also passes unchanged from this submission folder after sourcing the environment:

```sh
PORT=3105 bash ../../test/run.sh .
```

Choose an unused port so the runner's disposable server does not share the interactive server's port. The runner creates and removes its own database clone. This command does not imply a clean Ubuntu installation or a full-seed test.

## Design notes

- [Research and selection](docs/RESEARCH.md): evidence, alternatives, uncertainties and the case for this architecture.
- [Competitor source review](docs/COMPETITOR_REVIEW.md): leading implementations, reproduced parser observations and specific improvement opportunities.
- [Architecture](docs/ARCHITECTURE.md): ownership, scheduling, batching and correctness boundaries.
- [Performance experiments](docs/PERFORMANCE.md): current rules/leaderboard recheck and reproducible local A/B measurements.
- [Database recovery](docs/RECOVERY.md): connection ownership, setup, deadlines, failures and uncertain commits.
- [Development and cleanup](docs/DEVELOPMENT.md): native Mac setup policy, milestone gates and removal inventory.

## Current validation

The Zig server passes all 197 development-seed conformance steps through both the unchanged upstream runner and the focused milestone 5 harness. The unchanged Go reference also passes 197/197, and every normalized response matches. Twelve unit checks and the earlier 11 tags, 13 auth, 15 profile and 15 article/feed scenarios pass, together with 15 write scenarios.

All API routes are implemented. This is a native Mac correctness result, not an official capacity score, full-seed result or Linux runtime validation.

The auth checks include cross-verification with the unmodified Go reference for 72-byte, UTF-8 and embedded-NUL passwords. Zig 0.17 renders bcrypt as $2b$ and compares that version marker during verification; my adapter accepts the seed's corrected $2a$ format by normalizing only the marker before performing bcrypt. New passwords over 72 bytes are rejected; login verification follows Go's bcrypt truncation behaviour. Every login to an existing account still performs bcrypt verification, and changing the stored hash affects the next attempt.

A blocked update is tested to withhold success until the lock is released and the write commits. A separate database session confirms visibility after success. Forty concurrent logins exercise bounded overload while tags requests continue; rejected password jobs return 503 and are counted. These are correctness checks, not capacity measurements.

Profile reads query the current relationship for the requesting viewer. Follow and unfollow each use one parameterized statement with a target lookup and data-modifying CTE. Their responses wait for transaction completion, including deferred commit errors. Repeated operations keep the requested following state. Tests cover external changes, concurrent duplicates, blocked writes and a deferred commit failure that rolls back the inserted relation.

All 18 normalized profile responses match the unchanged Go reference, which passes all 197 steps on a separate fresh clone. One deliberate difference outside that transcript follows the specification: a present empty Authorization header returns 401. The Go reference treats that header as absent. Dynamic usernames are decoded once as path segments, preserving literal plus signs and encoded separators.

Article lists select page IDs in descending order before enrichment, then run a separate capped count, preserving the reference's statement order and snapshot behaviour. Counts stop at 1,000 without limiting which pages are accessible. Tag, author and favourited filters have the required precedence; unknown filters produce empty lists. Every request computes viewer-dependent flags from the database. Single articles include body; list objects omit it. Zig serializes JSON and decodes PostgreSQL text arrays; SQL formats UTC timestamps with three truncated fractional digits.

The read tests cover empty pages that still need a count, duplicate and encoded query parameters, escaped tag names, timestamps before 1970, 96 concurrent reads, failed page/count queries and slow/disconnected readers. Valid large feed offsets return empty pages with the correct count; the reference's int32 arithmetic returns 500 for a tested valid offset. My feed query uses overflow-safe arithmetic. No speedup is claimed from these correctness checks.

Article creation keeps its article, distinct tags and tag links inside one explicit transaction, then reads the committed article by ID. A failed stage is drained and rolled back before another request can use the connection. Ownership predicates are part of update/delete statements. Favourites are idempotent; comment lists return the newest 100 by creation time and ID. Successful deletions send a bodyless 204.

The write checks inject tag/link and deferred-commit failures, block a transaction mid-write, and verify that no partial article is visible. Eight simultaneous Zig/Go creates on the same disposable database all link the same new tag correctly. Tests also cover 64 repeated favourite writes, concurrent comments, cascade deletion, disconnects and backend loss. If a write commits but its follow-up read fails, the response is 503 and the write is never automatically replayed.

The Linux source path passes object-only cross-compilation; no linked Linux server has been run. There are no official scores.

The first local performance experiment compares named prepared queries with the previous unprepared build. Across three runs of each on fresh development-seed clones, median throughput increased from 3,055.7 to 4,523.6 requests/s (+48.0%), and median p95 decreased from 35.615 to 17.471 ms. All 687,440 measured requests succeeded. The six-core Apple Silicon Mac with 8 GiB RAM also ran the generator and PostgreSQL; each run measured thirty seconds with accelerated think/session times. This selects a local candidate and does not establish official capacity. Complete settings, per-run results and limitations are in [PERFORMANCE.md](docs/PERFORMANCE.md). `-Dprepared-queries=false` retains an unprepared control; PostgreSQL's plan-selection heuristic remains unchanged.

The second experiment compares one, two and four owners in the same recovering implementation. Across three fresh-clone runs per setting, median throughput is 4,430.1 / 6,163.1 / 6,447.0 requests/s. Four owners improve the one-owner control by 45.5%, with median p95 falling from 17.679 to 2.073 ms. All 1,549,517 measured requests succeed. These are separate short Mac experiments; their gains must not be added or compounded. Four is the current measured local default, still requiring full-seed and target-hardware validation. `-Ddb-connections=1` preserves the simple control; the checked build-time range is 1–95.

Ten recovery/concurrency scenarios additionally pass, including a stalled authentication exchange, repeated backend loss, lost COMMIT acknowledgement and a full restart of the dedicated project cluster. The server retains exactly one committed article when its acknowledgement is lost and never replays the write. A blocked writer leaves other owners serving; a timed-out transaction rolls back. All 197 unchanged upstream steps pass after recovery.

Current limits are deliberate: four database connections, 256 client slots, two bcrypt workers and at most 16 outstanding password jobs. Headers are limited to 16 KiB, bodies to 64 KiB and total buffered request data to 84 KiB. Chunked bodies are rejected and the connection closed. Idle clients have a 70-second timeout; active requests and database work have deadlines. Each owned database session sets an eight-second statement timeout. Query errors are drained, transactions roll back when needed, and lost connections are replaced with bounded backoff while healthy owners continue. Batching, large-connection scheduling and the Ubuntu install script remain future work. Article reads have a 4 MiB retained-field and serialized-response bound; larger results return 503.

## Working principles

I preserve the challenge's schema, workload and conformance suite. I verify every token and every login, commit writes before replying, and retain no response or query-result cache across requests. I document measurements with their hardware, data, commit and duration. Any reused code keeps its original attribution and licence.
