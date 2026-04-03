// Shadows LDC's core.atomic with non-intrinsic implementations.
// LDC's version uses LLVM atomic intrinsics (llvm_atomic_rmw_add etc.) which
// require hardware atomic support. Targets without native atomics (e.g. Xtensa)
// crash in LLVM instruction selection. This module provides plain load/store
// equivalents that are correct for single-core / cooperative-multitasking targets.
//
// Only included when uRT's import path (-I) precedes LDC's (post-switches).

module core.atomic;

nothrow @nogc @safe:

public import urt.atomic : MemoryOrder, cas,
    atomicLoad, atomicStore, atomicOp, atomicExchange,
    atomicFetchAdd, atomicFetchSub, TailShared;
