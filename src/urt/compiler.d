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

    // TODO: naked functions and other intrinsics still need GDC implementations
    // (see usage sites). Removed the eager static assert so the build can
    // progress past this module and surface the real gaps.
    enum IS_GDC = true;
}
else
    enum IS_GDC = false;

version (LDC_OR_GDC)
    enum IS_LDC_OR_GDC = true;
else
    enum IS_LDC_OR_GDC = false;
