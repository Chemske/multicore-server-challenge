# Zig Reactor — Chemske

Front: direct

**Status: research and proposed architecture. No server has been implemented yet.**

I am building a Conduit implementation for the Multicore Server Challenge, targeting the highest sustainable official score. My development environment is native macOS on Apple Silicon. I keep the toolchain, database, caches and generated files within one project workspace wherever the tools allow it.

My design starts with a small event-driven server in Zig, the official PostgreSQL client library in non-blocking mode, and a scheduler that combines compatible database work already waiting to run. The implementation will speak HTTP/1.1 directly, without Nginx.

The central idea is simple: **make each request create less work for the whole machine, especially PostgreSQL.** More threads are not automatically more useful when the application and database share eight CPUs.

## Proposed stack

| Component | Choice |
|---|---|
| Application | Zig 0.17.0 |
| Networking | Small Zig reactor; kqueue on macOS, epoll on Linux |
| HTTP parsing | Pinned picohttpparser source, compiled into the application |
| PostgreSQL | PostgreSQL 18; libpq asynchronous API and pipeline mode |
| Authentication | Zig standard-library cryptography; HS256 and bcrypt cost 10 |
| Deployment | Direct HTTP; official Ubuntu 24.04 x86_64 runtime contract |

The application and scheduling logic will be Zig. libpq and picohttpparser are C libraries, not separate services or development applications. Their exact source versions, hashes, licences and build requirements must be locked before integration. No dependency is selected on an unverified performance claim.

## Design notes

- [Research and selection](docs/RESEARCH.md): evidence, alternatives, uncertainties and the case for this architecture.
- [Competitor source review](docs/COMPETITOR_REVIEW.md): leading implementations, reproduced parser observations and specific improvement opportunities.
- [Architecture](docs/ARCHITECTURE.md): ownership, scheduling, batching and correctness boundaries.
- [Development and cleanup](docs/DEVELOPMENT.md): native Mac setup policy, milestone gates and removal inventory.

## Current validation

The existing challenge tools have been built, and the existing load-generator tests passed during environment preparation. Zig also compiled and executed a limited selection of existing standard-library tests. These checks validate parts of the development environment; they do not validate this proposed server.

No implementation benchmarks, conformance pass, Linux execution or official score are claimed here. Installation, build and start scripts will be added during implementation. This folder is not ready for submission.

## Working principles

I preserve the challenge's schema, workload and conformance suite. I verify every token and every login, commit writes before replying, and retain no response or query-result cache across requests. I document measurements with their hardware, data, commit and duration. Any reused code keeps its original attribution and licence.
