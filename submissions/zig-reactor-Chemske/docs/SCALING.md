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

Twenty-two Zig unit checks cover framing, claims, typed arrays, queue unlink/reuse, 100,000 simulated scheduler slots and independent bcrypt lanes. Focused integration tests compare every grouped page family against sequential results, mix authenticated viewers and missing resources, retain sub-millisecond comment order, inject SQL errors, and verify fresh reads after a group completes.

A count-boundary test pauses the second SQL statement, inserts a new article externally, and proves that the page remains the captured page while the later count sees the insert. Dedicated-writer tests block every writer, queue more writes, verify fresh reads still progress, then check every committed write. Recovery tests retain the lost-COMMIT-acknowledgement case without replay.

`tests/reactor.py --reactors N` requires every Linux reactor to serve real requests; an existing listener is insufficient. It also checks 384 concurrent reads, 2,048 pipelined immediate errors and partial output. Darwin's `SO_REUSEPORT` does not balance these listeners like Linux, so native Mac validation uses one reactor.

`tests/linux_connections.py` checks 150,000 retained sockets and an HTTP response on each, followed by database reads on reused sockets. It uses several loopback source addresses to avoid the per-destination ephemeral-port ceiling. It does not claim 150,000 workload users. The test changes no kernel settings; the CI helper raises only its own descriptor limit to match the benchmark service.

Build-time controls live in `build.zig`: `reactors`, `db-connections`, `write-connections`, `max-tasks`, `max-clients`, `read-batch-size`, `bcrypt-workers`, `bcrypt-jobs`, `bcrypt-lanes`, `bcrypt-gather-ms`, `feed-prune`, `page-batch`, `comments-batch`, `article-batch`, `tag-batch`, `generic-plans`, `prepared-queries`, `eager-write` and `epoll-pause`. Runtime configuration remains exactly the four variables in the challenge contract.

`benchmarks/linux_compare.py` preserves raw results, endpoint histograms, workload mix, error counts, generator-limit flags, executable fingerprints and diagnostics. Each run uses a fresh full-seed clone and removes its temporary server/database even on failure. CI-only workflow changes stay on the fork's separate diagnostic branch, outside the submission pull request.

## Independent password work

[Run 40775117771](https://github.com/Chemske/multicore-server-challenge/actions/runs/40775117771) compared full cost-ten bcrypt calculations on one x86_64 CPU thread, with three trials of 60 distinct password/salt pairs per variant. Median CPU time per hash was 60.833 ms for the standard library, 58.433 ms for one custom lane, 30.850 ms for two, 22.750 ms for three and 19.233 ms for four. All trial checksums agreed. The full-width backend therefore delivered about 3.16 times the scalar throughput in this microbenchmark. This measures complete hash work, not application throughput or user capacity.

The worker integration keeps each hash independent and uses the scalar path for a singleton. `tests/password_batch.py` mixes concurrent registrations, correct logins and incorrect logins, verifies response ownership, checks fresh independent salts, asks the unchanged Go reference to verify each new hash, and changes a stored hash externally before another login group. Its log check requires an actual multi-job calculation rather than merely enabling the build flag. A bounded collection window is experimental; its effect on tail latency must be measured with external generators before changing defaults.

## Integrated Linux validation

[Run 40961667314](https://github.com/Chemske/multicore-server-challenge/actions/runs/40961667314), on 29 October, passed the integrated revision with two reactors, 16 total database connections including four dedicated writers, 8,192 admitted tasks, read groups up to 128, four password lanes and a maximum 75 ms password collection window. It passed all 22 unit checks, grouped page/comment fault tests, mixed password jobs, blocked-writer isolation, real progress on both reactors, 15 mutation scenarios and nine recovery scenarios. Zig and the Go reference each passed all 197 unchanged conformance steps on the development seed. Post-recovery conformance passed too.

The same run retained 150,000 real Linux sockets, obtained an HTTP response on every socket and then read from the database over reused connections. The application reported approximately 28.3 MiB RSS in this socket check, excluding the kernel, PostgreSQL and the generators. Idle CPU rounded to 0.00% of one core over the test's interval. This establishes the socket machinery's correctness under that test; it does not establish 150,000 active workload users, full-load memory consumption or a new leaderboard score.

## Feed candidate pruning

A bounded rank lookup can reduce the number of followed-author articles merged for a page. Let `depth = offset + limit`. If one followed author has at least `depth` articles, its `depth`-th article ID is a safe lower bound: the union already contains `depth` articles at or above that ID. Older articles from any author cannot enter this page. The bound and page are read within the same statement, and the separate count statement remains unchanged.

The optional `feed-prune` control probes at most eight followed authors and at most 256 ranks. Without a usable bound, including deeper pages, the query retains the ordinary merge. The fallback is the minimum signed article ID, so correctness does not depend on positive IDs. No bound survives the statement. Both individual and grouped feeds use the same SQL generator.

`tests/feed_prune.py` compares 62 API results with the independent full feed relation. Cases include empty/sparse follow sets, early authors without enough rows, interleaved authors, negative IDs, deep offsets, maximum integer offsets and fresh follow/article changes. The existing grouped-page and page-before-count tests still apply. A related within-statement rank-bound strategy appears in the [Rust epoll submission's feed query](https://github.com/arjaythedev/multicore-server-challenge/blob/2f2b650/submissions/rust-epoll-theCatWisel/src/queries.rs); this implementation retains its own separate page/count snapshots and bounded per-page probe.
