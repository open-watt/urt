// GDC-side shadow for druntime's core.internal.newaa.
//
// GDC lowers AA literals `[k1:v1, k2:v2]` to a direct call to
// core.internal.newaa._d_assocarrayliteralTX, ignoring uRT's hook re-exported
// through `object`. With `-I src` ahead of GDC's bundled D include path, this
// module wins import resolution and forwards the call to uRT's template-based
// AA implementation in urt.internal.aa.
//
// Without this shadow, GDC pulls its bundled core.internal.newaa which tries
// to allocate `Bucket[]` arrays via the GC -- incompatible with -fno-druntime.
module core.internal.newaa;

public import urt.internal.aa : _d_assocarrayliteralTX;
