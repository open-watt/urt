module urt.attribute;

version (GNU)
{
    // gcc.attributes.naked is gated to architectures GDC's frontend
    // pre-recognizes -- on aarch64 it's silently dropped (warning + no
    // effect), and on x86_64 it doesn't actually emit a naked function.
    // The generic attribute("naked") mechanism passes the attribute through
    // to the GCC backend directly and works on every arch where GCC
    // itself supports __attribute__((naked)).
    import gcc.attributes : attribute;
    enum naked = attribute("naked");
}
version (LDC)
    public import ldc.attributes;

version (DigitalMars)
{
    enum restrict;
    enum weak;
}
