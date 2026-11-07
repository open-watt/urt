module test_dmd_bounds;

import urt.exception : assert_handler;
import urt.internal.stdc.stdlib : exit;

nothrow @nogc:

private __gshared uint expected_line;

int main(string[] args)
{
    if (args.length != 2)
        return 2;

    int[1] values;
    assert_handler = &check_bounds;
    if (args[1] == "index")
    {
        expected_line = __LINE__ + 1;
        return 2 + (values[args.length] & 1);
    }
    if (args[1] == "slice")
    {
        expected_line = __LINE__ + 1;
        return 2 + cast(int)values[0 .. args.length].length;
    }
    return 2;
}

private void check_bounds(string file, size_t line, string message)
{
    exit(line == expected_line && file == __FILE__ ? 0 : 1);
}
