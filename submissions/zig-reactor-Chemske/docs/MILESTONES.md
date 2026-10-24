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

## Milestone 3: execution plan

Implement profile reads, follow and unfollow. Profile reads allow anonymous access only when the Authorization header is absent; a present invalid header returns 401. Follow/unfollow require a verified token. The viewer is a parameter on every query, never connection state or cached profile data.

Dynamic usernames are matched as one encoded path segment, decoded exactly once, validated and copied before the HTTP input buffer moves. This preserves literal plus signs, Unicode and encoded separators without turning a username into a different route.

Each follow/unfollow uses one parameterized SQL statement containing the target lookup and the mutation in its own implicit transaction. Repeated operations return the requested following state even if no row changes. The response uses the target snapshot and explicit operation result; it does not reread the follows table inside the data-modifying CTE's old snapshot. No success is sent until libpq reaches the completed transaction boundary. This follows [PostgreSQL 18's documented CTE semantics](https://www.postgresql.org/docs/18/queries-with.html#QUERIES-WITH-MODIFYING).

The gate is the unchanged upstream users/auth and profiles sections, targeted viewer isolation/idempotence/commit/failure tests, a comparison with the unchanged Go reference, and the earlier milestone regressions. Feed and article routes remain the next checkpoint. No new installed software is needed.

## Milestone 3: results

Date: 2026-10-24. Profile reads, follow and unfollow are implemented. The request-lifetime module is now named requests.zig because it serves both users and profiles; SQL and username-path policy for profiles live in profiles.zig.

- ReleaseSafe build and eight unit checks passed, including route boundaries and single-pass URL decoding.
- All 50 users/auth and all 16 profile steps reached before comment creation pass in the unchanged suite. The full Zig run reports 137 steps, 73 passed and 64 failed, then aborts at unimplemented comment creation. Two profile calls in the later comments section remain unreached. This is not a full conformance pass.
- A fresh full run of the unchanged Go reference passed 197/197 steps. All 16 reached normalized profile responses match it exactly.
- Fifteen profile scenarios passed: upstream contract; normalized comparison; an independent Go/Zig follow/unfollow trace; encoded names; strict auth; committed row counts; self-follow; fresh reads after mutation/rename; fragmented/pipelined requests with changing identities; invalid paths; 64 contending requests; blocked follow and unfollow; deferred commit failure; SQL errors/reuse; client disconnect during a blocked write.
- The deferred-failure test inserts a relation, rejects the transaction at its commit boundary, requires 503, verifies that the row rolled back, and confirms connection reuse. Its temporary trigger exists only in the disposable test clone. No official schema or seed file changes are involved.
- The 11 tags and 13 auth regression scenarios still pass. Linux x86_64 semantic/object-only compilation passed; no linked or executed Linux validation or performance score is claimed.

The specification says a present invalid Authorization header is 401 even on optional-auth routes. The Go reference's Header.Get check treats an empty value as absent. I preserve header presence and return 401; a focused regression records this deliberate difference. Self-follow remains allowed, matching the fixed schema and the reference. Repeated operations are idempotent.

No software installation or automatic service was added. Both test clones and all temporary servers are removed. Results live under work/results/milestone3, with selected evidence copied to outputs.

## Milestone 4: execution plan

Implement article lists, the personal feed and single-article reads. Lists select IDs in descending order before enriching the selected page. Tag, author and favourited filters use the first non-empty value in that priority order; duplicate query parameters use their first value. Pagination accepts digit-only integers, with limit 1–100 and a non-negative signed-64-bit offset.

Keep the reference's page-then-capped-count execution order, with a separate statement snapshot for each stage. The HTTP request owns both results, and no partial response escapes if either stage fails. The same connection owner drains each query completely before starting the next stage. Empty pages still run the count. The feed keeps the reference's per-followed-author candidate selection but uses overflow-safe arithmetic for valid large offsets.

Zig serializes the API objects, validates PostgreSQL text-array results and omits body only in list objects. UTC timestamp formatting is explicit in SQL and truncates to milliseconds. Viewer-dependent favourites/following are evaluated on every request. No response, count or relationship cache is added.

The gate is the unchanged read-only portion of the upstream script before favourite writes, normalized comparison with the Go reference, targeted filter/pagination/serialization/freshness/failure checks and all earlier regressions. Later reads that depend on unimplemented writes remain visible failures. Source, test databases and caches stay in the existing workspace.

## Milestone 4: results

Date: 2026-10-24. Article lists, the personal feed and single-article reads are implemented. URL path decoding moved from profiles.zig to url.zig; the same module now owns query decoding/pagination. Article query families and DTO serialization live in articles.zig. Shared test lifecycle helpers were extracted from milestone 3 without removing its checks.

- ReleaseSafe build and eleven unit checks passed. Linux x86_64 semantic/object-only compilation passed; no linked Linux runtime is claimed.
- All 119 upstream steps before favourite writes passed, including all 51 article/feed read checks. Every normalized response in that prefix matches the unchanged Go reference. Its fresh full run passed 197/197.
- The full Zig run reports 141 steps, 123 passed and 18 failed, then aborts at missing comment creation. Favourite/comment writes and reads depending on those writes remain incomplete. Two later profile calls remain unreached. This is not a full conformance pass.
- Fifteen article/feed scenarios passed: upstream read gate; normalized comparison; single-object escaping/arrays/UTC dates; ordering and compact lists; precedence and empty pages; duplicate/encoded query parameters; feed and viewer flags; auth; mutation freshness; fragmented/pipelined requests; 96 concurrent reads; all five count families above the cap and large offsets; count-stage failure; page-stage failure/reuse; slow readers and response bounds.
- Five query families retain articlesCount = 1000 even for pages after offset 1000. Valid offsets through signed-64-bit maximum produce empty pages without integer wraparound. A tested reference feed request at offset 2147483647 fails with 500 due to int32 casts; my query follows the allowed pagination range instead.
- A private row-level-security fault rejects only the second/count statement. Both a populated and an empty first page return 503 with no leaked partial list, then the connection works after fault removal. No schema file or shared database is changed by this check.
- Slow/disconnected readers of a 3 MiB article do not prevent tags from progressing. Escaped output beyond the 4 MiB response bound returns 503. This is a correctness/resource test, not a throughput measurement.
- The earlier 11 tags, 13 auth and 15 profile scenarios still pass, including the deferred-commit failure check.

No new tools or automatic services were installed. Temporary databases/servers are removed. Complete logs and normalized transcripts are under work/results/milestone4; selected evidence is copied to outputs. Optimisation, Linux runtime validation and an official score remain outstanding.

## Next checkpoint

Add the remaining writes, comments and favourites. Reconnection and additional protocol coverage belong before optimisation. Batching and pipeline depth are later controlled experiments against this simple execution path.
