// GDC-side shadow for druntime's core.internal.array.construction.
//
// uRT's src/object.d defines all the array-construction hooks GDC's lowering
// invokes. Re-export the whole `object` module to avoid selective-import
// quirks with extern(C) declarations under GDC.
module core.internal.array.construction;

public import object;
