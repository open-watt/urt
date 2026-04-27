// GDC-side shadow for druntime's core.internal.cast_.
//
// uRT's src/object.d defines _d_dynamic_cast / _d_interface_cast as extern(C);
// selective named imports of extern(C) symbols across modules don't always
// resolve cleanly under GDC, so re-export the whole `object` module.
module core.internal.cast_;

public import object;
