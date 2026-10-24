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

## Next checkpoint

Implement registration, login and the current-user routes with bcrypt cost 10 and strict HS256 handling. Establish the isolated transaction and input-validation paths first. Keep the unchanged suite as the contract, and track its progress without claiming a partial run is a full pass.

After users/auth, add profiles/follows and the read endpoints, then the remaining writes. Reconnection and additional protocol coverage belong before optimisation. Batching and pipeline depth are later controlled experiments against this simple execution path.
