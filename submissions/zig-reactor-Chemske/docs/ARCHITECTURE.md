# Proposed architecture

Status: target design. The native single-owner tags, users/auth and profiles/follows path is implemented. Multiple shards, batching, pipelines and reconnects remain planned. I keep the unbatched execution path as the correctness and measurement control.

## Ownership and flow

Each reactor shard owns its HTTP connections, PostgreSQL connections, queues and active response buffers. A connection stays with its owner. The macOS backend uses kqueue; the Linux backend uses epoll. Platform code is restricted to readiness events, wakeups, sockets and timers wherever possible. I will not assume identical SO_REUSEPORT behaviour across operating systems.

The request path is: receive and frame HTTP → validate input and authentication → enqueue a typed operation → dispatch prepared SQL → consume and validate its result → wait for commit where required → serialize and send → release request storage.

I will start with one shard for native bring-up. Worker and connection counts are measured choices rather than one worker per CPU. Database connections across all shards must remain at or below 95. Read and write ownership are separate; neither uses a thread per client.

The reactor monitors libpq's socket. It advances connection establishment, flushes output when writable, and consumes input when readable. No blocking `PQexec` belongs on the event-loop path. A PGconn has exactly one manipulating owner. Results and parameter storage have explicit lifetimes; strings borrowed from a PGresult cannot survive its release.

## HTTP lifecycle

Picohttpparser parses headers; my layer owns framing and policy. I will enforce consistent Content-Length/Transfer-Encoding handling, bounds on headers and bodies, correct partial-read behaviour, ordered responses and safe handling of pipelined bytes. Chunked bodies must either be supported correctly or rejected explicitly without reinterpreting their bytes as another request. Ambiguous framing is rejected and the connection closed.

Only active or incomplete requests own substantial buffers. Idle connections retain a compact state record. Slow output is registered for write readiness rather than blocking a shard. Request deadlines, idle deadlines and response sizes are bounded. Disconnects detach the HTTP recipient but do not allow an in-flight database connection to be reused before its results have been drained or the connection replaced.

Connection IDs include a generation so a late database or bcrypt completion cannot target a recycled socket slot. One request in progress per connection is the initial execution policy; already received subsequent bytes remain framed and ordered.

## Read scheduling

Pending reads are grouped by query family. A dispatch takes requests already queued before execution, with a bounded maximum. There is no artificial collection timer in the initial design. When little work is waiting, the batch contains one request.

Choose among families using oldest waiting work and bounded per-family occupancy. Avoid filling a long pipeline behind an expensive feed query. Compare an unbatched prepared path, SQL batching, and limited pipelining separately before combining them.

Every row is associated with a request ordinal. Empty result sets and empty list pages still need a completion and the correct count. Per-request validation, identity and viewer flags remain distinct. No database result or rendered response is retained for requests that arrive after dispatch.

Candidate SQL work: select page IDs before enrichment; preserve capped counts; share repeated viewer-independent work inside the statement; compute favourited/following per viewer; use a separate path for query families whose batches cost more than they save. Preserve exact ordering, filter precedence, nullable fields and timestamp formatting.

Batch statements share a snapshot. I will document the resulting consistency semantics and verify API behaviour rather than claiming that sequential and concurrent executions are universally identical. Prepared generic/custom plans and session-only settings are measured per statement, not enabled blindly.

## Writes and commit boundaries

The first write path executes isolated transactions and responds only after confirmed commit. Article/tag creation remains atomic. Ownership checks, expected unique violations and not-found results retain the required API semantics.

Group commit is a later optimisation. Requests already waiting may share a transaction, but each response waits for successful commit acknowledgement. Expected-conflict operations may be kept separate initially. A failed group must be fully rolled back and drained before individual retries. Retry only where the rollback outcome is known and the error is eligible, with bounded retries.

Connection loss during commit means the outcome may be unknown. I will not replay the write automatically. An HTTP client disconnect does not undo an already committed operation. Data-modifying CTEs do not automatically expose their new rows through ordinary table scans; response queries must respect statement snapshots and read-after-commit requirements.

## Authentication and expensive work

Use HS256 with strict algorithm, signature, expiry and claim validation on every applicable request. The issued token has exactly the required subject and timestamps. Optional auth distinguishes an absent token from an invalid one; no-auth routes follow their own contract.

Bcrypt uses cost 10 and fresh salts. Verification runs on every login. Its queue and worker budget are bounded and separate from socket progress. Start with standard-library bcrypt and test compatibility with seeded hashes and the API's password-length rules. No verification cache and no initial assembly path.

## Errors, overload and recovery

Every queue, batch and in-flight set has limits on count and retained bytes, with request age/deadlines considered before dispatch. Overload is visible and measured; I will not call a run successful by omitting failed requests. PostgreSQL failures are drained to a known protocol boundary or the connection is replaced. Reconnection rebuilds prepared statements and session settings. Request arguments and credentials never enter routine logs.

HTTP error mapping follows the conformance suite. Transaction failures must not leak aborted state into another request. A single lost backend should not corrupt other connection owners or misroute completions.

## First implementation gates

1. Project-contained PostgreSQL 18 and libpq available; toolchain and parser source pinned.
2. Non-blocking native connection/query proof, then an HTTP tags endpoint that actually queries PostgreSQL.
3. Single-request execution, remaining endpoints and unchanged conformance.
4. Protocol, concurrency, rollback and recovery tests.
5. Read batches with differential checks; repeated A/B measurements.
6. Group commit and bcrypt improvements only when justified by profiling.
7. Linux CI and clean installation checks; official benchmark submission later.

The planned source areas are platform, reactor, HTTP, auth, PostgreSQL, scheduler, SQL, serialization and API handlers. This document does not create those modules or imply they already work.
