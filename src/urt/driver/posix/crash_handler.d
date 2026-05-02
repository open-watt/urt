/// POSIX crash handler - install signal handlers for fatal signals
/// (SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT) that print a stack trace
/// to stderr before re-raising for the kernel's default action
/// (core dump / abnormal termination).
///
/// Async-signal-safety: the trace path goes through dladdr and an
/// mmap'd .debug_line region, both of which take internal locks.
/// If the crash happens while those locks are held by the dynamic
/// linker the handler will deadlock - alarm(5) ensures we abort
/// rather than hang. fwrite to stderr likewise takes a libc lock;
/// we call fflush in a normal context (not the handler) is not
/// possible, so we accept the (rare) risk.
module urt.driver.posix.crash_handler;

version (linux):

import urt.internal.exception : capture_trace, print_trace, max_frames;
import urt.internal.sys.posix;

nothrow @nogc:


public void install_crash_handlers() @trusted
{
    if (_installed)
        return;
    _installed = true;

    // Alternate signal stack - lets the handler run when the original
    // stack is exhausted (stack-overflow SIGSEGV). Without this, the
    // handler attempt would itself fault.
    stack_t alt;
    alt.ss_sp    = _alt_stack.ptr;
    alt.ss_size  = _alt_stack.length;
    alt.ss_flags = 0;
    sigaltstack(&alt, null);

    sigaction_t sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND | SA_NODEFER;
    sa.sa_sigaction = &crash_handler;

    sigaction(SIGSEGV, &sa, null);
    sigaction(SIGBUS,  &sa, null);
    sigaction(SIGFPE,  &sa, null);
    sigaction(SIGILL,  &sa, null);
    sigaction(SIGABRT, &sa, null);
}


private:

// SIGSTKSZ * 2 - DWARF parsing scratch and trace formatting both want
// reasonable headroom; the kernel-suggested SIGSTKSZ is sometimes tight.
__gshared ubyte[16384] _alt_stack;
__gshared bool _installed;

extern(C) void crash_handler(int sig, siginfo_t* info, void* ctx) nothrow @nogc
{
    // Watchdog: if any of the trace-building locks deadlocks (libc fwrite,
    // dl_load_lock, mmap), make sure we still terminate.
    alarm(5);

    write_fatal_header(sig);

    void*[max_frames] frames;
    auto n = capture_trace(frames[]);
    if (n > 0)
    {
        write_str("  stack trace:\n");
        print_trace(frames[0 .. n]);
    }

    flush_stderr();

    // SA_RESETHAND restored the default disposition; SA_NODEFER means
    // the signal is not blocked while we're in the handler. raise()
    // therefore re-enters the kernel default handler, which will
    // core-dump for SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT.
    raise(sig);
}

void write_fatal_header(int sig) nothrow @nogc
{
    const(char)[] name;
    switch (sig)
    {
        case SIGSEGV: name = "SIGSEGV (segmentation fault)"; break;
        case SIGBUS:  name = "SIGBUS (bus error)";           break;
        case SIGFPE:  name = "SIGFPE (arithmetic exception)"; break;
        case SIGILL:  name = "SIGILL (illegal instruction)"; break;
        case SIGABRT: name = "SIGABRT (aborted)";            break;
        default:      name = "fatal signal";                 break;
    }
    write_str("\nFATAL: ");
    write_str(name);
    write_str("\n");
}

void write_str(const(char)[] s) nothrow @nogc
{
    if (s.length > 0)
        write(STDERR_FILENO, s.ptr, s.length);
}

void flush_stderr() nothrow @nogc
{
    // print_trace went through libc fwrite which is buffered; flush so
    // the output reaches the terminal/pipe before we re-raise and the
    // process aborts.
    import urt.io : flush, WriteTarget;
    flush!(WriteTarget.stderr)();
}
