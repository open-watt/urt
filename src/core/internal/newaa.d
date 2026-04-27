// GDC-side shadow for druntime's core.internal.newaa.
//
// GDC's bundled object.d always gets compiled (it's load-bearing for
// semantic analysis even with -fno-druntime), and that object.d imports
// AA hooks from core.internal.newaa. With `-I src` ahead of GDC's bundled
// D include path, this shadow wins import resolution and forwards the
// hooks to uRT's template-based AA implementation in urt.internal.aa.
//
// Without this shadow, GDC pulls its bundled core.internal.newaa which
// tries to GC-allocate `Bucket[]` arrays -- incompatible with -fno-druntime.
module core.internal.newaa;

public import urt.internal.aa :
    _d_assocarrayliteralTX,
    _d_aaNew,
    _d_aaLen,
    _d_aaGetY,
    _d_aaGetRvalueX,
    _d_aaIn,
    _d_aaDel,
    _d_aaApply,
    _d_aaApply2,
    _d_aaEqual;
