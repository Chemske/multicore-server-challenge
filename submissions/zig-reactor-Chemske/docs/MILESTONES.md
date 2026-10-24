# Implementation checkpoints

## Milestone 1: native bring-up

Date: 2026-10-24. This checkpoint implements only the tags route and the local test environment.

- PostgreSQL/libpq 18.6 built from official checked source into the workspace.
- Dedicated SCRAM-authenticated, loopback-only cluster; no automatic service.
- Development seed verified against upstream row counts and fingerprints: 100k users, 10k articles, 200 tags; approximately 95 MB seed database.
- Unmodified Go reference: 197 steps, 197 passed, zero failed on the native cluster.
- Zig ReleaseSafe build and protocol unit tests passed.
- Focused integration: 11 scenarios passed, including 64 requests over 16 simultaneous keep-alive connections, a split request, pipelined requests, close-token dominance, conflicting framing rejection, fresh data after mutation, SQL error/reuse and backend loss returning 503.
- Linux x86_64 object-only semantic compilation passed. This is not a linked or executed Linux validation.
- Bash helper syntax and Zsh environment-path checks passed.

The first implementation has one owner/event loop, one non-blocking database connection, generation-tagged clients and no data cache. HTTP inputs are limited to 16 KiB headers/32 KiB buffered data. Large tag responses are bounded at serialization, client slots are capped at 256, idle clients at 70 seconds, and active work has deadlines. No capacity score is implied by these correctness checks.

## Milestone 2: execution plan

Implement the four users/auth routes before profiles or articles. I keep the existing single-owner database path while adding parameterized statements and per-request storage. A response to a write waits until libpq has drained the statement through its completion boundary.

Two bcrypt workers share a maximum of 16 outstanding jobs, including running jobs and uncollected completions. A non-blocking pipe wakes the reactor. Workers only touch their job's fixed password/hash buffers; they never own sockets, PGconn objects or request allocators. Generation-tagged recipients prevent a late completion from reaching a reused client slot. Saturation returns 503 instead of growing memory without a bound.

HTTP framing gains a 64 KiB body limit and preserves pipelined bytes. JSON input is copied into request-owned storage before the receive buffer moves. HS256 verification validates the signature, algorithm, decimal string subject and integer expiry on every authenticated request. Registration and login issue the specified three claims; current-user responses preserve the presented token. No authentication or data cache is added.

The gate is: existing tags regressions, focused auth/concurrency/failure checks, and the unchanged upstream conformance transcript. The auth section must pass; failures in later, unimplemented endpoints remain visible. I will check Linux semantics without claiming a linked Linux run or an official performance result.

## Milestone 2: results

Date: 2026-10-24. Registration, login, current-user read and current-user update are implemented.

- ReleaseSafe build and six unit checks passed, including the unchanged Go seed's $2a$ bcrypt hash.
- All 50 users/auth steps in the unmodified upstream suite passed. The full run reports 137 steps, 61 passed, 76 failed and an abort in later unimplemented routes. It is not a full conformance pass.
- All 11 existing tags regression scenarios still pass, including 64 concurrent keep-alive requests and backend-loss handling.
- Thirteen auth scenarios passed: upstream contract; parameterized Unicode/quotes and signed claim checks; byte limits/NUL text; separate-session commit visibility; blocked-write acknowledgement; additional invalid tokens; current-hash verification; bcrypt cross-verification with the unmodified Go reference; fragmented bodies and pipelining; bounded overload with tags progress; disconnected bcrypt clients and 64 concurrent reads; duplicate-write contention; SQL error/reuse.
- The observed 40-login overload run accepted 16 and returned 503 for 24. Both outcomes are counted. No capacity score is inferred.
- New hashes have cost 10 and fresh secure salts. Both directions of Go/Zig interoperability passed for 72-byte ASCII, 72-byte UTF-8 and embedded-NUL passwords. Long login inputs preserve Go's verification semantics; long new passwords are rejected.
- Linux x86_64 semantic/object-only compilation passed; no linked or executed Linux validation.

No new application, package manager installation or background service was added. Test databases and temporary servers are removed by the test scripts. Results and the unchanged suite's complete log/transcript stay in work/results/milestone2; selected evidence is copied to outputs.

## Next checkpoint

Finish the users/auth gate above, then add profiles and follows.

After users/auth, add profiles/follows and the read endpoints, then the remaining writes. Reconnection and additional protocol coverage belong before optimisation. Batching and pipeline depth are later controlled experiments against this simple execution path.
