/**
 * Memory profiling tools.
 *
 * Two of them, answering different questions and priced differently:
 *
 *   `urt.mem.profile.log`    (make ALLOC_PROFILE=1)  logs an event per allocation and keeps ~50
 *                            bytes; the host replays the stream for lifetimes, watermarks and
 *                            per-call-site attribution. Affordable on the small targets.
 *
 *   `urt.mem.profile.record` (make ALLOC_TRACKING=1) keeps a live table so the target can answer
 *                            "what has leaked, right now" by itself, over a console, with no host
 *                            and no captured stream. Costs the table.
 *
 * Both hook `urt.mem.alloc` and can be enabled together.
 */
module urt.mem.profile;

public import urt.mem.profile.log;
public import urt.mem.profile.record;
