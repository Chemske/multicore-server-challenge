# Performance work

## Rules and leaderboard recheck

Checked on 2026-10-25 against upstream `c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e`. Fetching upstream showed no changes to the rules, schema, workload, test harness or leaderboard since my previous review.

The current official leaders are Rust/Tokio at 100,000 users, C#/Sockets at 95,000, and C/io_uring at 84,000. The leading Rust run reports 26,279 requests/s, p95 119 ms and p99 185 ms, with 20% application CPU and 70% PostgreSQL CPU. These are results on the official eight-vCPU, 16 GB box, with the full seed and separate load generators.

The score requires a five-minute hold with p95 below 500 ms, p99 below one second and fewer than 1% errors. A load-generator-limited run does not establish server capacity. The application shares its CPU and memory budget with PostgreSQL.

I keep these constraints throughout optimisation:

- Every request reads its data from PostgreSQL during service; no response, data, authentication or password-result caches.
- The schema, indexes, seed, workload and shared test files remain fixed. Prepared statements and connection pools are explicitly allowed. Total application database connections must stay at or below 95.
- Writes wait for durable commit. No asynchronous commit, speculative success or automatic replay after an uncertain write outcome.
- Every applicable request verifies HS256 and expiry. Every login verifies the current stored bcrypt hash; new hashes use cost 10 and fresh salts.
- Direct HTTP must eventually support tens of thousands of idle connections. The present 256-client limit is only a development limit.
- The submission must build from pinned source on Ubuntu 24.04 x86_64 and pass the unchanged conformance suite. A Mac run cannot establish this.

Sources: [rules and scoring](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/README.md), [runtime contract](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/SPEC.md), [workload](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/WORKLOAD.md), [leaderboard](https://github.com/arjaythedev/multicore-server-challenge/blob/c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e/LEADERBOARD.md).

## Experiment 1: named prepared queries

The control sends each statement with `PQsendQueryParams`, which parses the SQL again. The candidate prepares nineteen fixed queries on its own connection during startup and uses `PQsendQueryPrepared` for the existing users, profiles, tags and article-read path. The article/comment operation state machine retains its original parameterized path for this experiment. SQL text, parameters, serialization, commit boundaries, queueing, limits and worker counts are otherwise the same.

Preparation is completed and drained before the connection is admitted to the reactor, within the existing twenty-second startup budget. A preparation failure closes the connection and fails startup. Prepared names live only as long as that connection. This creates no persistent schema objects and retains no returned data. Database reconnection is still a separate checkpoint.

I keep PostgreSQL's default `plan_cache_mode=auto`. Forcing generic plans could reduce planning work further, but skewed tags, authors and pagination sizes can need different plans. That needs its own measured experiment. See [PostgreSQL PREPARE](https://www.postgresql.org/docs/18/sql-prepare.html) and [asynchronous libpq commands](https://www.postgresql.org/docs/18/libpq-async.html).

Build the current control with:

```sh
source dev/env.sh
zig build -Doptimize=ReleaseSafe -Dpg-root="$PGROOT" -Dprepared-queries=false
```

The normal build enables prepared queries. Copy each executable into a distinct directory under `work/` before comparing; rebuilding replaces `zig-out/bin/conduit`.

The standard-library-only `benchmarks/compare.py` launches the unchanged upstream load generator against fresh development-seed database copies. Its default order is A-B-B-A-B-A, with three runs of each build. It preserves complete raw results, failed requests, per-endpoint histograms, workload mix, generator-limit flags and binary fingerprints. It removes each temporary database and server, including on failure.

Example, using already saved executable copies:

```sh
python3 benchmarks/compare.py \
  --control "$CHALLENGE_WORK/experiments/prepared-statements/baseline" \
  --candidate "$CHALLENGE_WORK/experiments/prepared-statements/candidate" \
  --think-scale 0.005 \
  --out "$CHALLENGE_WORK/experiments/prepared-statements/comparison"
```

The output directory must be new. The measured run uses 128 virtual users, a ten-second ramp, thirty measured seconds and a three-second tail. Think times and sessions are accelerated together. The database has 100,000 users and 10,000 articles. Generator, server and database share this six-core Apple Silicon Mac with 8 GiB RAM. These short local comparisons can select a candidate; they cannot be converted into official user counts or compared directly to leaderboard throughput. Background Mac activity and stochastic workloads remain sources of noise.

### Results

The control is the saved ReleaseSafe executable from commit `68280865c4b2ec8efe3c191493ba1f973e4c1a0c`. The candidate uses the same compiler, optimisation mode, database and process limits, with the prepared-query change described above. No other tests or builds ran during the six-run comparison. The later default rebuild has the same SHA-256 as the measured candidate.

| Run | Build | Requests/s | p95 ms | p99 ms | Errors / measured requests |
|---|---|---:|---:|---:|---:|
| 1 | Control | 3,281.3 | 30.655 | 42.655 | 0 / 98,439 |
| 2 | Prepared | 4,756.5 | 16.543 | 28.047 | 0 / 142,696 |
| 3 | Prepared | 4,523.6 | 17.471 | 26.719 | 0 / 135,707 |
| 4 | Control | 3,008.1 | 38.015 | 49.791 | 0 / 90,243 |
| 5 | Prepared | 4,289.5 | 21.071 | 32.671 | 0 / 128,684 |
| 6 | Control | 3,055.7 | 35.615 | 48.287 | 0 / 91,671 |

Median throughput increases **48.0%**, from 3,055.7 to 4,523.6 requests/s. The median of the per-run p95 values decreases from 35.615 to 17.471 ms, and the median p99 from 48.287 to 28.047 ms. Every prepared run exceeds every control run. There are zero errors across 687,440 measured requests, with approximately 5% writes in each run. All generator-limit flags are false. Host-wide CPU sampling is unavailable on macOS; the generator reports about 3.2–4.3% process CPU across the first three runs. I do not infer an official generator-capacity verdict from that.

Throughput drifts down across the experiment, so the alternating controls matter. The result supports keeping this change on the development workload. It does not prove a 48% improvement on the full seed or the official hardware. The complete JSON, endpoint distributions, binary hashes and transcripts remain under `work/experiments/prepared-statements/comparison/`, outside the submitted source.

The candidate passes twelve Zig unit checks, the unchanged official runner's 197 steps, normalized comparison of all 197 responses against the unchanged Go reference, and the existing 11/13/15/15/15 focused scenario groups. The optional unprepared build also passes the complete write gate and 197-step reference comparison. Linux object-only semantic compilation succeeds; a linked Linux runtime, clean installer and full-seed run remain outstanding.

## Next experiments

After this first comparison, finish connection recovery, then measure bounded database concurrency and read batching independently. Replace linear client scans and the development connection limit before large direct-HTTP tests. Only then consider group commit, binary result decoding or specialised bcrypt work if profiling supports them. Keep an unbatched prepared control throughout.
