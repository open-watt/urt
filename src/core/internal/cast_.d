// GDC-side shadow for druntime's core.internal.cast_.
//
// GDC's bundled object.d compiles this submodule for class/interface-cast
// hooks, and the bundled implementation references `object.TypeInfo` in
// ways that fail with -fno-rtti. uRT's src/object.d defines the hooks we
// need; forward them so GDC's -I src lookup picks ours first.
module core.internal.cast_;

public import object :
    _d_dynamic_cast,
    _d_interface_cast;
