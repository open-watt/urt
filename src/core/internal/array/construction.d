// GDC-side shadow for druntime's core.internal.array.construction.
//
// GDC's bundled object.d gets compiled regardless of -fno-druntime, and
// pulls in this submodule for array-construction hooks (`new T[]`,
// `arr.length = N` lowering, etc.). The bundled implementation references
// `object.TypeInfo` inside templates that fail with -fno-rtti.
//
// uRT's src/object.d already defines all the hooks GDC needs; this shadow
// just forwards them so GDC picks them up via -I src priority.
module core.internal.array.construction;

public import object :
    _d_newarrayT,
    _d_newarraymTX,
    _d_arrayassign_l,
    _d_arrayassign_r,
    _d_arraysetlengthT,
    _d_arraysetlengthTImpl,
    _d_newclassT;
