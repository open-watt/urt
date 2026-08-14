module urt.mem.profile.common;

version (AllocProfile)  version = AnyMemProfile;
version (AllocTracking) version = AnyMemProfile;

version (AnyMemProfile):

import urt.time : MonoTime, get_time;

nothrow @nogc:


alias Sink = void delegate(const(char)[]) nothrow @nogc;

// Milliseconds, not MonoTime: both tools store or emit stamps in bulk, and only ever compare
// them as deltas. Wrapping is fine at that scale, eight bytes each is not.
uint time_ms()
    => cast(uint) (get_time() - MonoTime()).as!"msecs";
