module urt.compiler;

public import urt.attribute;

version (DigitalMars)
    enum IS_DMD = true;
else
    enum IS_DMD = false;

version (LDC)
{
    version = LDC_OR_GDC;

    enum IS_LDC = true;
}
else
    enum IS_LDC = false;

version (GNU)
{
    version = LDC_OR_GDC;

    // GDC support, established mechanisms:
    //   - Naked functions:    @naked UDA from gcc.attributes (re-exported via urt.attribute).
    //   - Inline asm:         GCC extended-asm syntax inside `asm { "..." : : : "..."; }`.
    //                         See urt.fibre x86_64 SystemV co_swap for the reference example.
    //   - Builtins/intrinsics: `import gcc.builtins;` (see urt.intrinsic).
    //
    // Per-arch context-switching asm and other compiler-specific bits not yet
    // ported to GDC carry their own static asserts at the usage site -- those
    // remain real TODOs.
    enum IS_GDC = true;
}
else
    enum IS_GDC = false;

version (LDC_OR_GDC)
    enum IS_LDC_OR_GDC = true;
else
    enum IS_LDC_OR_GDC = false;
