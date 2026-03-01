/// Minimal std.math stub — provides just the `pow` function that DMD's
/// `^^` operator lowering requires.  Nothing else from Phobos is pulled in.
module std.math;

// DMD lowers `a ^^ b` to `std.math.pow(a, b)`.
public import urt.math : pow;

// TODO: do we need sqrt for `^^ 0.5`?
