// Force-included via -include when compiling tlsf.c on M0.
// TLSF's only printf calls are unreachable in our use (bad-arg validation
// in tlsf_create/tlsf_add_pool, and the debug walker callback) -- we
// control the args and never call the walker. Silencing them at compile
// time keeps picolibc's printf and stdio FILE machinery out of the link.
#ifndef TLSF_SILENT_H
#define TLSF_SILENT_H

static inline int tlsf_silent_printf(const char *fmt, ...) { (void)fmt; return 0; }
#define printf tlsf_silent_printf

#endif
