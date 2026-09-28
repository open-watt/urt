module urt.build;

// The consuming project's revision, as its build wrote it; builds that write none report "unknown".
static if (__traits(compiles, import("build_id")))
    enum string build_id = import("build_id");
else
    enum string build_id = "unknown";
