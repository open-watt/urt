// Minimal POSIX bindings — only what URT actually uses.
// Replaces imports of core.sys.posix.* to avoid druntime's transitive
// core.stdc.stdio dependency (stdint → wchar_ → stdio).

module urt.internal.sys.posix;

version (Posix):
extern(C) nothrow @nogc:

// ── types ──

alias off_t = long;
alias mode_t = uint;
alias ssize_t = ptrdiff_t;
alias time_t = long;
alias clockid_t = int;
alias blkcnt_t = long;
alias dev_t = ulong;
alias ino_t = ulong;
alias uid_t = uint;
alias gid_t = uint;

version (X86)
{
    alias blksize_t = int;
    alias nlink_t = uint;
}
else version (X86_64)
{
    alias blksize_t = long;
    alias nlink_t = ulong;
}
else version (AArch64)
{
    alias blksize_t = int;
    alias nlink_t = uint;
}
else version (ARM)
{
    alias blksize_t = int;
    alias nlink_t = uint;
}
else version (RISCV32)
{
    alias blksize_t = int;
    alias nlink_t = uint;
}
else version (RISCV64)
{
    alias blksize_t = int;
    alias nlink_t = uint;
}
else
    static assert(false, "POSIX type aliases not defined for this arch");

// ── fcntl ──

enum O_RDONLY   = 0x0;
enum O_WRONLY   = 0x1;
enum O_RDWR     = 0x2;
enum O_CREAT    = 0x40;
enum O_TRUNC    = 0x200;
enum O_APPEND   = 0x400;
enum O_NOCTTY   = 0x100;
enum O_NDELAY   = 0x800;  // same as O_NONBLOCK
enum O_CLOEXEC  = 0x80000;

version (linux)
    enum O_DIRECT = 0x4000;

version (X86)
{
    // glibc x86: largefile64 redirects
    int open64(scope const char* pathname, int flags, ...);
    alias open = open64;
}
else
    int open(scope const char* pathname, int flags, ...);
int fcntl(int fd, int cmd, ...);

version (Darwin)
{
    enum F_NOCACHE = 48;
    enum F_GETPATH = 50;
}

enum F_GETFL = 3;
enum F_SETFL = 4;
enum O_NONBLOCK = 0x800;

// ── unistd ──

int close(int fd);
int unlink(scope const char* pathname);
ssize_t read(int fd, void* buf, size_t count);
ssize_t write(int fd, const void* buf, size_t count);
version (X86)
{
    off_t lseek64(int fd, off_t offset, int whence);
    alias lseek = lseek64;
    int ftruncate64(int fd, off_t length);
    alias ftruncate = ftruncate64;
}
else
{
    off_t lseek(int fd, off_t offset, int whence);
    int ftruncate(int fd, off_t length);
}
ssize_t readlink(scope const char* path, char* buf, size_t bufsiz);
version (X86)
{
    ssize_t pread64(int fd, void* buf, size_t count, off_t offset);
    alias pread = pread64;
    ssize_t pwrite64(int fd, const void* buf, size_t count, off_t offset);
    alias pwrite = pwrite64;
}
else
{
    ssize_t pread(int fd, void* buf, size_t count, off_t offset);
    ssize_t pwrite(int fd, const void* buf, size_t count, off_t offset);
}
int fsync(int fd);
int usleep(uint usec);
long sysconf(int name);
int gethostname(char* name, size_t len);

enum _SC_PAGE_SIZE   = 30;
enum _SC_PHYS_PAGES  = 85;

enum STDIN_FILENO  = 0;
enum STDOUT_FILENO = 1;
enum STDERR_FILENO = 2;
int isatty(int fd);

// ── sys/stat ──

version (X86_64)
{
    // x86_64 is unique: nlink before mode, long blksize/blocks, long[3] tail
    struct stat_t
    {
        dev_t st_dev;
        ino_t st_ino;
        nlink_t st_nlink;
        mode_t st_mode;
        uid_t st_uid;
        gid_t st_gid;
        uint __pad0;
        dev_t st_rdev;
        off_t st_size;
        long st_blksize;
        long st_blocks;
        timespec st_atim;
        timespec st_mtim;
        timespec st_ctim;
        long[3] __unused;
    }
    static assert(stat_t.sizeof == 144);
}
else version (X86)     version = OldStatLayout;
else version (ARM)     version = OldStatLayout;
else version (AArch64) version = NewStatLayout;
else version (RISCV32) version = NewStatLayout;
else version (RISCV64) version = NewStatLayout;
else
    static assert(false, "stat_t not defined for this arch");

version (NewStatLayout)
{
    // AArch64, RISCV32, RISCV64: new kernel stat layout
    struct stat_t
    {
        dev_t st_dev;
        ino_t st_ino;
        mode_t st_mode;
        nlink_t st_nlink;
        uid_t st_uid;
        gid_t st_gid;
        dev_t st_rdev;
        ulong __pad1;
        off_t st_size;
        blksize_t st_blksize;
        int __pad2;
        blkcnt_t st_blocks;
        timespec st_atim;
        timespec st_mtim;
        timespec st_ctim;
        int[2] __unused;
    }
    static assert(stat_t.sizeof == 128);
}

version (OldStatLayout)
{
    // X86, ARM: old glibc stat layout with __USE_FILE_OFFSET64
    private struct __timespec32 { int tv_sec; int tv_nsec; }
    struct stat_t
    {
        dev_t st_dev;
        ushort __pad1;
        uint __st_ino;
        mode_t st_mode;
        nlink_t st_nlink;
        uid_t st_uid;
        gid_t st_gid;
        dev_t st_rdev;
        ushort __pad2;
        off_t st_size;
        blksize_t st_blksize;
        blkcnt_t st_blocks;
        version (CRuntime_Musl)
        {
            __timespec32 __st_atim32;
            __timespec32 __st_mtim32;
            __timespec32 __st_ctim32;
        }
        ino_t st_ino;
        timespec st_atim;
        timespec st_mtim;
        timespec st_ctim;
    }
}

bool S_ISREG(mode_t mode)
    => (mode & 0xF000) == 0x8000;

version (X86)
{
    int stat64(scope const char* pathname, stat_t* buf);
    alias stat = stat64;
    int fstat64(int fd, stat_t* buf);
    alias fstat = fstat64;
    int mkstemp64(char* tmpl);
    alias mkstemp = mkstemp64;
}
else
{
    int stat(scope const char* pathname, stat_t* buf);
    int fstat(int fd, stat_t* buf);
    int mkstemp(char* tmpl);
}
int mkdir(scope const char* pathname, mode_t mode);
pure int posix_memalign(void** memptr, size_t alignment, size_t size);

// ── time ──

struct timespec
{
    time_t tv_sec;
    long tv_nsec;
}

struct tm
{
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
    long tm_gmtoff;
    const(char)* tm_zone;
}

enum CLOCK_REALTIME  = 0;
enum CLOCK_MONOTONIC = 1;

int clock_gettime(clockid_t clk_id, timespec* tp);
int clock_settime(clockid_t clk_id, const timespec* tp);
tm* gmtime_r(scope const time_t* timep, tm* result);
time_t mktime(tm* tp);

// ── sys/mman ──

enum PROT_READ  = 0x1;
enum MAP_PRIVATE = 0x02;
enum MAP_FAILED = cast(void*)-1;

void* mmap(void* addr, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void* addr, size_t length);

// ── dlfcn ──

struct Dl_info
{
    const(char)* dli_fname;
    void* dli_fbase;
    const(char)* dli_sname;
    void* dli_saddr;
}

int dladdr(scope const void* addr, Dl_info* info);

// ── netinet/in ──
// in6_addr and sockaddr_in6 are provided by ImportC (urt.internal.os)
// on platforms that use it. Defined here as fallback for others.

version (none)
{
    struct in6_addr
    {
        ubyte[16] s6_addr;
    }

    struct sockaddr_in6
    {
        ushort sin6_family;
        ushort sin6_port;
        uint sin6_flowinfo;
        in6_addr sin6_addr;
        uint sin6_scope_id;
    }
}

// ── poll ──

struct pollfd
{
    int fd;
    short events;
    short revents;
}

enum POLLIN     = 0x001;
enum POLLPRI    = 0x002;
enum POLLOUT    = 0x004;
enum POLLERR    = 0x008;
enum POLLHUP    = 0x010;
enum POLLNVAL   = 0x020;
enum POLLRDNORM = 0x040;
enum POLLWRNORM = 0x100;

int poll(pollfd* fds, size_t nfds, int timeout);
