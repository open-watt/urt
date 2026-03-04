#pragma attribute(push, nothrow, nogc)

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

// The errno macro expands to (*__errno_location()) on Linux. ImportC would
// generate a function symbol `errno` that clashes with libc's TLS errno.
#undef errno

// Some errno values are defined as chained macros (e.g. ENOTSUP → EOPNOTSUPP,
// EWOULDBLOCK → EAGAIN) that ImportC cannot resolve to integers.
// Re-define as plain integer literals so ImportC can export them.
#undef ENOTSUP
#define ENOTSUP 95    /* == EOPNOTSUPP on Linux */
#undef EWOULDBLOCK
#define EWOULDBLOCK 11  /* == EAGAIN on Linux */
