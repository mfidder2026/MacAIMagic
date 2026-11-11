Patch 0002 (expert streaming) rebased onto upstream llama.cpp `2cbe0ec` (2026-11-11), for when the pin moves.
Patch 0001 applies there unchanged. `scripts/build_engine.sh` does not use this folder (it reads `patches/*.patch`).

What changed in the rebase: upstream replaced the SLRU expert cache with a class-based LRU (#31233) and added misses
computed on the CPU (#30966). "Not cached" is now a slot at `n_slots` or later instead of -1; the read-ahead uses that.
The warm start saves each expert with its class ("MOE2") and still reads the file of the current engine ("MOE1":
probation and protected become classes 0 and 1). The slot map is written from `l.slot_map`, because with a CPU part
the looked-up map is `slot_map_cpu`, whose data is not used.

Measured: docs/RESEARCH.md section 16.
