# Scaling beyond the first official result

## What failed in version 1

The [first official run](https://github.com/arjaythedev/multicore-server-challenge/pull/73) at `a026224` held 20,000 users for five minutes: 5,241 requests/s, p50 1.2 ms, p95 318 ms, p99 453 ms and 0.15% errors. Above that level, errors were predominantly admission 503s, with total target CPU still at 44%. The four-connection pool and 2,048-task ceiling could leave work waiting while the box had spare CPU. Raising a limit alone would only turn rejection into a longer queue.

I changed the ownership and SQL paths, then compared actual Linux binaries rather than extrapolating from the Mac.

## Changes

- Independent reactors own their listeners, client slots, queues, database sessions and bcrypt jobs. Linux distributes connections with `SO_REUSEPORT`. No reactor is restarted after failure.
- Read and write queues have separate database owners. A transaction waiting on a lock or durable commit cannot occupy every read connection. Counts stay part of their original read operation.
- Tags, article details, comments and all five list families group compatible requests that are already queued. There is no collection delay. Nothing joins a dispatched group, and no returned data survives it.
- Page metadata and capped counts are computed once per distinct filter/window within the group, while favourite/follow flags remain specific to each viewer. Pages and counts remain separate statements in that order.
- Responses try a non-blocking send immediately. Partial writes resume on readiness; pipelined immediate responses advance iteratively. Linux pauses keep an `EPOLLONESHOT` registration rather than removing and adding a descriptor around each query.
- Typed JWT claims avoid generic object maps while retaining signature, algorithm, subject, expiry and claim-type checks on every request. Bcrypt still verifies the stored hash at cost 10 on every login.
- Per-reactor logs distinguish capacity rejection, password admission and database failures. The comparison harness records each reactor thread's CPU and PostgreSQL wait classes without collecting application SQL or parameter values.

Resource limits remain explicit. Connection counts and task/buffer budgets are totals split across reactors; adding a reactor does not multiply them. No data caches, schema changes, server-wide PostgreSQL settings, asynchronous commits or uncertain-write replay are introduced.

## First Linux diagnostic: more concurrency alone

[Run 40684259256](https://github.com/Chemske/multicore-server-challenge/actions/runs/40684259256) compared the original binary with the earlier scaling revision through `4fdf976`, before grouped pages and dedicated writers. It used Ubuntu 24.04 x86_64, PostgreSQL 18, the unchanged full seed and published database settings in a disposable CI service. Application, database and generator shared a four-vCPU, 16-GiB runner. This is a relative comparison, not the official eight-vCPU box with an external generator.

Each variant passed all 197 unchanged full-seed conformance steps. The repeated order was A-B-C-D-D-C-B-A, 20,000 normal-clock users, 15-second ramp, 30-second measurement and three-second tail. Medians of the two per-run values:

| Variant | Reactors / DB owners / admitted tasks | Requests/s, including errors | p95 ms | p99 ms | Errors |
|---|---|---:|---:|---:|---:|
| A: official version 1 | 1 / 4 / 2,048 | 5,210 | 84 | 2,993 | 11.36% |
| B: early scaling revision | 1 / 4 / 2,048 | 5,213 | 128 | 2,608 | 10.01% |
| C: early scaling revision | 2 / 8 / 8,192 | 4,989 | 1,952 | 3,202 | 0.83% |
| D: early scaling revision | 4 / 16 / 8,192 | 5,110 | 1,163 | 1,892 | 0% |

Every run reported `lg_limited=false`; that does not make the shared runner equivalent to the official topology. B reached exactly its admission ceiling and its 503s were capacity rejections. D eliminated those rejections but still failed the latency limits. This is why I added page groups and read/write isolation instead of declaring the larger queue a success. Reactor CPU samples also did not show a saturated event-loop core on this runner, so these results alone do not prove a single-reactor CPU bottleneck.

## Correctness and reproducibility

Nineteen Zig unit checks cover framing, claims, typed arrays, queue unlink/reuse and 100,000 simulated scheduler slots. Focused integration tests compare every grouped page family against sequential results, mix authenticated viewers and missing resources, retain sub-millisecond comment order, inject SQL errors, and verify fresh reads after a group completes.

A count-boundary test pauses the second SQL statement, inserts a new article externally, and proves that the page remains the captured page while the later count sees the insert. Dedicated-writer tests block every writer, queue more writes, verify fresh reads still progress, then check every committed write. Recovery tests retain the lost-COMMIT-acknowledgement case without replay.

`tests/reactor.py --reactors N` requires every Linux reactor to serve real requests; an existing listener is insufficient. It also checks 384 concurrent reads, 2,048 pipelined immediate errors and partial output. Darwin's `SO_REUSEPORT` does not balance these listeners like Linux, so native Mac validation uses one reactor.

`tests/linux_connections.py` checks 100,000 retained sockets and an HTTP response on each, followed by database reads on reused sockets. It uses several loopback source addresses to avoid the per-destination ephemeral-port ceiling. It does not claim 100,000 workload users. The test changes no kernel settings; the CI helper raises only its own descriptor limit to match the benchmark service.

Build-time controls live in `build.zig`: `reactors`, `db-connections`, `write-connections`, `max-tasks`, `max-clients`, `read-batch-size`, `bcrypt-workers`, `bcrypt-jobs`, `page-batch`, `comments-batch`, `article-batch`, `tag-batch`, `generic-plans`, `prepared-queries`, `eager-write` and `epoll-pause`. Runtime configuration remains exactly the four variables in the challenge contract.

`benchmarks/linux_compare.py` preserves raw results, endpoint histograms, workload mix, error counts, generator-limit flags, executable fingerprints and diagnostics. Each run uses a fresh full-seed clone and removes its temporary server/database even on failure. CI-only workflow changes stay on the fork's separate diagnostic branch, outside the submission pull request.
