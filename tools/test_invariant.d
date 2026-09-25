module test_invariant;

import urt.exception : assert_handler;
import urt.internal.stdc.stdlib : exit;
import urt.mem : alloc, free;

nothrow @nogc:

private uint base_calls, derived_calls;

private class Base
{
    invariant() { ++base_calls; }
}

private class Derived : Base
{
    invariant() { ++derived_calls; }
}

int main()
{
    auto value = alloc!Derived();
    base_calls = derived_calls = 0;
    _d_invariant_impl(value);
    version (D_TypeInfo)
        assert(base_calls == 1 && derived_calls == 1);
    else
        assert(base_calls == 0 && derived_calls == 0);
    free(value);

    // A null object must still assert when metadata traversal is disabled.
    assert_handler = (string file, size_t line, string msg) nothrow @nogc { exit(0); };
    _d_invariant_impl(null);
    return 1;
}
