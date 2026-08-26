module urt.file;

import urt.mem;
import urt.platform;
import urt.result;
import urt.string.uni;
import urt.time;

public import urt.result;

// Backend selection is additive: each enabled backend is consulted in turn.
version (UseSpiffs)   version = HasFileBackend;
version (UseLittleFS) version = HasFileBackend;

// A flat backend stores one object per whole path and has no directory nodes;
// Directory synthesises them from '/' in those names.
version (UseSpiffs) version = EmulateDirectories;

version (HasFileBackend)
{
    import urt.meta : AliasSeq;

    version (UseLittleFS)
    {
        import urt.fs.littlefs;
        private alias LittleFsBackends = AliasSeq!(LittleFsBackend);
    }
    else
        private alias LittleFsBackends = AliasSeq!();

    version (UseSpiffs)
    {
        import urt.fs.spiffs;
        private alias SpiffsBackends = AliasSeq!(SpiffsBackend);
    }
    else
        private alias SpiffsBackends = AliasSeq!();

    // littlefs first: where both are built it is the one to create new files in.
    private alias FileBackends = AliasSeq!(LittleFsBackends, SpiffsBackends);

    private enum : int { seek_set = 0, seek_cur = 1, seek_end = 2 }
}

alias SystemTime = void;

version(Windows)
{
    import urt.internal.sys.windows.winbase;
    import urt.internal.sys.windows;
    import urt.internal.sys.windows.windef : MAX_PATH;
    import urt.internal.sys.windows.winnt;
    import urt.string : twstringz;

    // TODO: remove this when LDC/GDC are up to date...
    version (DigitalMars) {} else {
        extern(Windows) DWORD GetFinalPathNameByHandleW(HANDLE hFile, LPWSTR lpszFilePath, DWORD cchFilePath, DWORD dwFlags) nothrow @nogc;
        enum FILE_NAME_OPENED = 8;
    }
}
else version (Posix)
{
    import urt.internal.sys.posix;
    import urt.internal.stdc.errno;
    import urt.mem.temp : tconcat;
    import urt.string : tstringz;

    enum SEEK_SET = 0;
    enum SEEK_CUR = 1;
    enum SEEK_END = 2;

    enum POSIX_FADV_NORMAL = 0;
    enum POSIX_FADV_RANDOM = 1;
    enum POSIX_FADV_SEQUENTIAL = 2;
    extern(C) int posix_fadvise(int fd, off_t offset, off_t len, int advice) nothrow @nogc;
    extern(C) int rename(scope const char*, scope const char*) nothrow @nogc;
}
else version (FreeStanding)
{
    // No filesystem on bare-metal
}
else
{
    static assert(0, "Not implemented");
}

nothrow @nogc:


enum FileResult
{
    Success,
    Failure,
    AccessDenied,
    AlreadyExists,
    DiskFull,
    NotFound,
    NoData
}

enum FileOpenMode
{
    Write,
    ReadWrite,
    ReadExisting,
    ReadWriteExisting,
    WriteTruncate,
    ReadWriteTruncate,
    WriteAppend,
    ReadWriteAppend
}

enum FileOpenFlags
{
    None            = 0,
    NoBuffering     = (1 << 1), // The file or device is being opened with no system caching for data reads and writes.
    RandomAccess    = (1 << 2), // Access is intended to be random. The system can use this as a hint to optimize file caching. Mutually exclusive with `SequentialScan`.
    Sequential      = (1 << 3), // Access is intended to be sequential from beginning to end. The system can use this as a hint to optimize file caching. Mutually exclusive with `RandomAccess`.
}

enum FileAttributeFlag
{
    None            = 0,
    Directory       = (1 << 0),
    Hidden          = (1 << 1),
    ReadOnly        = (1 << 2),
    Symlink         = (1 << 3),
}

struct FileAttributes
{
    FileAttributeFlag attributes;
    ulong size;

    SysTime createTime;
    SysTime accessTime;
    SysTime writeTime;
}

struct File
{
    version (Windows)
        void* handle = INVALID_HANDLE_VALUE;
    else version (Posix)
        int fd = -1;
    else version (FreeStanding)
    {
        int fd = -1;
        version (HasFileBackend)
            ubyte backend = ubyte.max;
    }
    else
        static assert(0, "File: not implemented for this platform");
}

// One entry from a Directory walk. `name` points at storage owned by the
// Directory, so it lives only until the next read or the close.
struct DirEntry
{
    const(char)[] name;
    ulong size;
    FileAttributeFlag attributes;

    bool is_directory() const pure nothrow @nogc
        => (attributes & FileAttributeFlag.Directory) != 0;
    bool is_symlink() const pure nothrow @nogc
        => (attributes & FileAttributeFlag.Symlink) != 0;
}

version (EmulateDirectories)
{
    private enum max_emulated_prefix = 64;
    private enum max_emulated_name = 32;
    // A listing with more distinct subdirectories than this repeats one.
    private enum max_emulated_seen = 8;

    private const(char)[] strip_slashes(const(char)[] path)
    {
        size_t b = 0, e = path.length;
        while (b < e && path[b] == '/')
            ++b;
        while (e > b && path[e - 1] == '/')
            --e;
        return path[b .. e];
    }

    private bool emulated_open(alias B)(ref Directory dir, const(char)[] path)
    {
        const(char)[] rel = strip_slashes(path);
        if (rel.length + 1 > max_emulated_prefix)
            return false;

        // the root always exists; any other name only when something lives under it
        if (rel.length)
        {
            int probe = B.scan_open();
            if (probe < 0)
                return false;
            bool found = false;
            char[256] buffer = void;
            for (;;)
            {
                ulong size;
                ptrdiff_t len = B.scan_read(probe, buffer[], size);
                if (len <= 0)
                    break;
                const(char)[] n = buffer[0 .. len];
                if (n.length > rel.length && n[0 .. rel.length] == rel && n[rel.length] == '/')
                {
                    found = true;
                    break;
                }
            }
            B.scan_close(probe);
            if (!found)
                return false;
        }

        int fd = B.scan_open();
        if (fd < 0)
            return false;
        dir.fd = fd;
        dir.prefix[0 .. rel.length] = rel[];
        dir.prefix_len = cast(ubyte)rel.length;
        if (rel.length)
        {
            dir.prefix[rel.length] = '/';
            dir.prefix_len = cast(ubyte)(rel.length + 1);
        }
        dir.seen_count = 0;
        return true;
    }

    private bool emulated_seen(ref Directory dir, const(char)[] child)
    {
        foreach (i; 0 .. dir.seen_count)
        {
            if (dir.seen_len[i] == child.length && dir.seen[i][0 .. child.length] == child)
                return true;
        }
        if (child.length <= max_emulated_name && dir.seen_count < max_emulated_seen)
        {
            dir.seen[dir.seen_count][0 .. child.length] = child[];
            dir.seen_len[dir.seen_count] = cast(ubyte)child.length;
            ++dir.seen_count;
        }
        return false;
    }

    private bool emulated_read(alias B)(ref Directory dir, out DirEntry entry)
    {
        const(char)[] prefix = dir.prefix[0 .. dir.prefix_len];
        for (;;)
        {
            ulong size;
            ptrdiff_t len = B.scan_read(dir.fd, dir.name_buffer[], size);
            if (len <= 0)
                return false;

            const(char)[] flat = dir.name_buffer[0 .. len];
            if (flat.length <= prefix.length || flat[0 .. prefix.length] != prefix)
                continue;
            const(char)[] rest = flat[prefix.length .. $];

            size_t slash = 0;
            while (slash < rest.length && rest[slash] != '/')
                ++slash;
            if (slash == rest.length)
            {
                entry.name = rest;
                entry.size = size;
                return true;
            }

            const(char)[] child = rest[0 .. slash];
            if (emulated_seen(dir, child))
                continue;
            entry.name = child;
            entry.size = 0;
            entry.attributes |= FileAttributeFlag.Directory;
            return true;
        }
    }
}

struct Directory
{
    version (Windows)
    {
        void* handle = INVALID_HANDLE_VALUE;
        WIN32_FIND_DATAW find_data = void;
        bool pending;   // find_data holds the entry FindFirstFileW already produced
        char[MAX_PATH * 3] name_buffer = void;
    }
    else version (Posix)
        DIR* dir;
    else version (FreeStanding)
    {
        int fd = -1;
        version (HasFileBackend)
        {
            ubyte backend = ubyte.max;
            char[256] name_buffer = void;
            version (EmulateDirectories)
            {
                ubyte prefix_len;
                ubyte seen_count;
                char[max_emulated_prefix] prefix = void;
                char[max_emulated_name][max_emulated_seen] seen = void;
                ubyte[max_emulated_seen] seen_len = void;
            }
        }
    }
    else
        static assert(0, "Directory: not implemented for this platform");
}

bool file_exists(const(char)[] path)
{
    version (Windows)
    {
        DWORD attr = GetFileAttributesW(path.twstringz);
        return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
    }
    else version (Posix)
    {
        stat_t st;
        return stat(path.tstringz, &st) == 0 && S_ISREG(st.st_mode);
    }
    else version (HasFileBackend)
    {
        static foreach (B; FileBackends)
            if (B.exists(path))
                return true;
        return false;
    }
    else
        return false;
}

Result delete_file(const(char)[] path)
{
    version (Windows)
    {
        if (!DeleteFileW(path.twstringz))
            return getlasterror_result();
    }
    else version (Posix)
    {
        if (unlink(path.tstringz) == -1)
            return errno_result();
    }
    else version (HasFileBackend)
    {
        static foreach (B; FileBackends)
        {
            if (B.exists(path))
                return B.remove(path) ? Result.success : InternalResult.failed;
        }
        return InternalResult.failed;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

Result rename_file(const(char)[] oldPath, const(char)[] newPath)
{
    version (Windows)
    {
        if (!MoveFileW(oldPath.twstringz, newPath.twstringz))
            return getlasterror_result();
    }
    else version (Posix)
    {
        if (int result = rename(oldPath.tstringz, newPath.tstringz) != 0)
           return posix_result(result);
    }
    else version (HasFileBackend)
    {
        static foreach (B; FileBackends)
        {
            if (B.exists(oldPath))
                return B.rename(oldPath, newPath) ? Result.success : InternalResult.failed;
        }
        return InternalResult.failed;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

Result copy_file(const(char)[] oldPath, const(char)[] newPath, bool overwriteExisting = false)
{
    version (Windows)
    {
        if (!CopyFileW(oldPath.twstringz, newPath.twstringz, !overwriteExisting))
            return getlasterror_result();
        return Result.success;
    }
    else
    {
        // byte-copy through this module's own File API, which covers every
        // backend alike; only Windows has a native copy worth preferring
        if (!overwriteExisting && file_exists(newPath))
            return InternalResult.already_exists;

        File src, dst;
        Result r = src.open(oldPath, FileOpenMode.ReadExisting, FileOpenFlags.Sequential);
        if (!r)
            return r;
        r = dst.open(newPath, FileOpenMode.WriteTruncate);
        if (!r)
        {
            src.close();
            return r;
        }

        ubyte[4096] buffer = void;
        for (;;)
        {
            size_t got;
            r = src.read(buffer[], got);
            if (!r || got == 0)
                break;
            size_t written;
            r = dst.write(buffer[0 .. got], written);
            if (!r)
                break;
            if (written != got)
            {
                r = InternalResult.failed;
                break;
            }
        }
        src.close();
        dst.close();
        if (!r)
            delete_file(newPath); // don't leave a half-written target behind
        return r;
    }
}

Result get_path(ref const File file, ref char[] buffer)
{
    version (Windows)
    {
        // TODO: waiting for the associated WINAPI functions to be merged into druntime...

        wchar[MAX_PATH] tmp = void;
        DWORD dwPathLen = tmp.length - 1;
        DWORD result = GetFinalPathNameByHandleW(cast(HANDLE)file.handle, tmp.ptr, dwPathLen, FILE_NAME_OPENED);
        if (result == 0 || result > dwPathLen)
            return getlasterror_result();

        size_t pathLen = tmp[0..result].uni_convert(buffer);
        if (!pathLen)
            return InternalResult.buffer_too_small;
        if (buffer.length >= 4 && buffer[0..4] == `\\?\`)
            buffer = buffer[4..pathLen];
        else
            buffer = buffer[0..pathLen];
    }
    else version (Darwin)
    {
        import urt.mem : strlen;

        char[PATH_MAX] src = void;
        int r = fcntl(file.fd, F_GETPATH, src.ptr);
        if (r == -1)
            return errno_result();
        size_t l = strlen(src.ptr);
        if (l > buffer.length)
            return InternalResult.buffer_too_small;
        buffer[0..l] = src[0..l];
        buffer = buffer[0..l];
    }
    else version (Posix)
    {
        ptrdiff_t r = readlink(tconcat("/proc/self/fd/", file.fd, '\0').ptr, buffer.ptr, buffer.length);
        if (r == -1)
            return errno_result();
        if (r == buffer.length)
        {
            // TODO: if r == buffer.length, truncation MAY have occurred, but also maybe not...
            //       is there any way to fix this? for now, we'll just assume it did and return an error
            return InternalResult.buffer_too_small;
        }
        buffer = buffer[0..r];
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result set_file_times(ref File file, const SystemTime* createTime, const SystemTime* accessTime, const SystemTime* writeTime);

Result get_file_attributes(const(char)[] path, out FileAttributes outAttributes)
{
    version (Windows)
    {
        WIN32_FILE_ATTRIBUTE_DATA attrData = void;
        if (!GetFileAttributesExW(path.twstringz, GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, &attrData))
            return getlasterror_result();

        outAttributes.attributes = FileAttributeFlag.None;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) == FILE_ATTRIBUTE_HIDDEN)
            outAttributes.attributes |= FileAttributeFlag.Hidden;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY)
            outAttributes.attributes |= FileAttributeFlag.ReadOnly;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == FILE_ATTRIBUTE_DIRECTORY)
        {
            outAttributes.attributes |= FileAttributeFlag.Directory;
            outAttributes.size = 0;
        }
        else
            outAttributes.size = cast(ulong)attrData.nFileSizeHigh << 32 | attrData.nFileSizeLow;

        outAttributes.createTime = SysTime(cast(ulong)attrData.ftCreationTime.dwHighDateTime << 32 | attrData.ftCreationTime.dwLowDateTime);
        outAttributes.accessTime = SysTime(cast(ulong)attrData.ftLastAccessTime.dwHighDateTime << 32 | attrData.ftLastAccessTime.dwLowDateTime);
        outAttributes.writeTime = SysTime(cast(ulong)attrData.ftLastWriteTime.dwHighDateTime << 32 | attrData.ftLastWriteTime.dwLowDateTime);
    }
    else version (Posix)
    {
        stat_t st;
        if (stat(path.tstringz, &st) != 0)
            return errno_result();

        outAttributes.attributes = FileAttributeFlag.None;
        if (S_ISDIR(st.st_mode))
        {
            outAttributes.attributes |= FileAttributeFlag.Directory;
            outAttributes.size = 0;
        }
        else
            outAttributes.size = st.st_size;

        // st_ctim is inode-change time; POSIX has no creation time, this is the nearest thing
        outAttributes.createTime = from_unix_time_ns(st.st_ctim.tv_sec * 1_000_000_000UL + st.st_ctim.tv_nsec);
        outAttributes.accessTime = from_unix_time_ns(st.st_atim.tv_sec * 1_000_000_000UL + st.st_atim.tv_nsec);
        outAttributes.writeTime = from_unix_time_ns(st.st_mtim.tv_sec * 1_000_000_000UL + st.st_mtim.tv_nsec);
    }
    else version (HasFileBackend)
    {
        static foreach (B; FileBackends)
        {
            if (B.exists(path))
            {
                ulong size;
                if (!B.stat(path, size))
                    return InternalResult.failed;
                outAttributes.attributes = FileAttributeFlag.None;
                outAttributes.size = size;
                return Result.success;
            }
        }
        return InternalResult.failed;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

Result get_attributes(ref const File file, out FileAttributes outAttributes)
{
    version (Windows)
    {
        // TODO: waiting for the associated WINAPI functions to be merged into druntime...
/+
        FILE_BASIC_INFO basicInfo = void;
        FILE_STANDARD_INFO standardInfo = void;
        if (!GetFileInformationByHandleEx(cast(HANDLE)file.handle, FILE_INFO_BY_HANDLE_CLASS.FileBasicInfo, &basicInfo, FILE_BASIC_INFO.sizeof))
            return getlasterror_result();
        if (!GetFileInformationByHandleEx(cast(HANDLE)file.handle, FILE_INFO_BY_HANDLE_CLASS.FileStandardInfo, &standardInfo, FILE_STANDARD_INFO.sizeof))
            return getlasterror_result();

        outAttributes.attributes = FileAttributeFlag.None;
        if ((basicInfo.FileAttributes & FILE_ATTRIBUTE_HIDDEN) == FILE_ATTRIBUTE_HIDDEN)
            outAttributes.attributes |= FileAttributeFlag.Hidden;
        if ((basicInfo.FileAttributes & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY)
            outAttributes.attributes |= FileAttributeFlag.ReadOnly;
        if (standardInfo.Directory == TRUE)
        {
            outAttributes.attributes |= FileAttributeFlag.Directory;
            outAttributes.size = 0;
        }
        else
            outAttributes.size = standardInfo.EndOfFile.QuadPart;

        outAttributes.createTime = SysTime(basicInfo.CreationTime.QuadPart);
        outAttributes.accessTime = SysTime(basicInfo.LastAccessTime.QuadPart);
        outAttributes.writeTime = SysTime(basicInfo.LastWriteTime.QuadPart);

        return Result.success;
+/
    }
    else version (Posix)
    {
        // TODO
        assert(false);
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        outAttributes.attributes = FileAttributeFlag.None;
        outAttributes.size = file.get_size();
        return Result.success;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return InternalResult.unsupported;
}

void[] load_file(const(char)[] path)
{
    File f;
    Result r = f.open(path, FileOpenMode.ReadExisting);
    if (!r)
    {
        if (r.file_result == FileResult.NotFound)
            return null;
        return null; // TODO: are there any errors we can handle?
    }
    ulong size = f.get_size();
    assert(size <= size_t.max, "File is too large");
    void[] buffer = alloc(cast(size_t)size);
    size_t bytesRead;
    r = f.read(buffer[], bytesRead);
    assert(r, "TODO: handle error");
    f.close();
    return buffer[0..bytesRead];
}

Result save_file(const(char)[] path, const(void)[] data)
{
    File f;
    Result r = f.open(path, FileOpenMode.WriteTruncate);
    if (!r)
        return r;
    size_t written;
    r = f.write(data, written);
    f.close();
    if (!r)
        return r;
    if (written != data.length)
        return InternalResult.failed;
    return Result.success;
}

Result create_directory(const(char)[] path)
{
    Result r;
    version (Windows)
    {
        if (CreateDirectoryW(path.twstringz, null))
            return Result.success;
        r = getlasterror_result();
    }
    else version (Posix)
    {
        if (!urt.internal.sys.posix.mkdir(tconcat(path, "\0").ptr, 493 /* 0755 */) != 0)
            return Result.success;
        r = errno_result();
    }
    else version (HasFileBackend)
    {
        // create in the backend new files land in (the first); a flat
        // namespace has no directories, the name simply works as a prefix
        alias B = FileBackends[0];
        static if (is(typeof(B.mkdir)))
            return B.mkdir(path) ? Result.success : InternalResult.failed;
        else
            return Result.success;
    }
    else
    {
        return InternalResult.unsupported; // no filesystem on this platform
    }

    if (r == InternalResult.already_exists)
        return Result.success;
    return r;
}

// Removes an empty directory; a populated one is refused by the filesystem.
Result remove_directory(const(char)[] path)
{
    version (Windows)
    {
        if (!RemoveDirectoryW(path.twstringz))
            return getlasterror_result();
    }
    else version (Posix)
    {
        if (urt.internal.sys.posix.rmdir(tconcat(path, "\0").ptr) != 0)
            return errno_result();
    }
    else version (HasFileBackend)
    {
        static foreach (B; FileBackends)
        {
            if (B.exists(path))
                return B.remove(path) ? Result.success : InternalResult.failed;
        }
        return InternalResult.failed;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

Result open(ref Directory dir, const(char)[] path)
{
    version (Windows)
    {
        import urt.mem.temp : tconcat;

        // FindFirstFileW enumerates a wildcard, not a directory, and it
        // produces the first entry up front rather than on the first read.
        const(char)[] pattern = tconcat(path, path.length && path[$-1] != '\\' && path[$-1] != '/' ? "\\*" : "*");
        dir.handle = FindFirstFileW(pattern.twstringz, &dir.find_data);
        if (dir.handle == INVALID_HANDLE_VALUE)
            return getlasterror_result();
        dir.pending = true;
    }
    else version (Posix)
    {
        dir.dir = opendir(path.tstringz);
        if (dir.dir is null)
            return errno_result();
    }
    else version (HasFileBackend)
    {
        static foreach (i, B; FileBackends)
        {
            if (dir.fd < 0)
            {
                static if (B.flat)
                {
                    if (emulated_open!B(dir, path))
                        dir.backend = i;
                }
                else
                {
                    int fd = B.dir_open(path);
                    if (fd >= 0)
                    {
                        dir.fd = fd;
                        dir.backend = i;
                    }
                }
            }
        }
        if (dir.fd < 0)
        {
            static foreach (B; FileBackends)
            {
                if (B.available())
                    return InternalResult.failed;
            }
            return InternalResult.unsupported;
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

// Returns false at the end of the directory, so a failure to open and an
// exhausted walk read the same way at the call site.
bool read(ref Directory dir, out DirEntry entry)
{
    version (Windows)
    {
        if (dir.handle == INVALID_HANDLE_VALUE)
            return false;
        for (;;)
        {
            if (!dir.pending && !FindNextFileW(cast(HANDLE)dir.handle, &dir.find_data))
                return false;
            dir.pending = false;

            size_t wlen = 0;
            while (wlen < dir.find_data.cFileName.length && dir.find_data.cFileName[wlen] != 0)
                ++wlen;
            char[] name = dir.name_buffer[];
            size_t len = dir.find_data.cFileName[0 .. wlen].uni_convert(name);
            if (len == 0)
                continue;
            name = dir.name_buffer[0 .. len];
            if (name == "." || name == "..")
                continue;

            entry.name = name;
            entry.size = (cast(ulong)dir.find_data.nFileSizeHigh << 32) | dir.find_data.nFileSizeLow;
            if (dir.find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                entry.attributes |= FileAttributeFlag.Directory;
            if (dir.find_data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN)
                entry.attributes |= FileAttributeFlag.Hidden;
            if (dir.find_data.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
                entry.attributes |= FileAttributeFlag.ReadOnly;
            if (dir.find_data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
                entry.attributes |= FileAttributeFlag.Symlink;
            return true;
        }
    }
    else version (Posix)
    {
        import urt.mem : strlen;

        if (dir.dir is null)
            return false;
        for (;;)
        {
            dirent* e = readdir(dir.dir);
            if (e is null)
                return false;

            const(char)[] name = e.d_name.ptr[0 .. strlen(e.d_name.ptr)];
            if (name == "." || name == "..")
                continue;

            // d_type is not filled in by every filesystem, so the stat below settles
            // both the size and the kind. It must not follow, or a link to a directory
            // is indistinguishable from the directory itself.
            stat_t st;
            if (fstatat(dirfd(dir.dir), e.d_name.ptr, &st, AT_SYMLINK_NOFOLLOW) == 0)
            {
                if (S_ISLNK(st.st_mode))
                {
                    entry.attributes |= FileAttributeFlag.Symlink;
                    // the kind and size reported stay those of the target, as before
                    stat_t target;
                    if (fstatat(dirfd(dir.dir), e.d_name.ptr, &target, 0) == 0)
                        st = target;
                }
                entry.size = st.st_size;
                if (S_ISDIR(st.st_mode))
                    entry.attributes |= FileAttributeFlag.Directory;
            }
            else if (e.d_type == DT_DIR)
                entry.attributes |= FileAttributeFlag.Directory;
            else if (e.d_type == DT_LNK)
                entry.attributes |= FileAttributeFlag.Symlink;

            if (name.length && name[0] == '.')
                entry.attributes |= FileAttributeFlag.Hidden;
            entry.name = name;
            return true;
        }
    }
    else version (HasFileBackend)
    {
        if (dir.fd < 0)
            return false;
        static foreach (i, B; FileBackends)
        {
            if (dir.backend == i)
            {
                static if (B.flat)
                    return emulated_read!B(dir, entry);
                else
                for (;;)
                {
                    bool is_dir;
                    ulong size;
                    ptrdiff_t len = B.dir_read(dir.fd, dir.name_buffer[], size, is_dir);
                    if (len <= 0)
                        return false;
                    const(char)[] name = dir.name_buffer[0 .. len];
                    if (name == "." || name == "..")
                        continue;
                    entry.name = name;
                    entry.size = size;
                    if (is_dir)
                        entry.attributes |= FileAttributeFlag.Directory;
                    return true;
                }
            }
        }
        return false;
    }
    else
        return false;
}

void close(ref Directory dir)
{
    version (Windows)
    {
        if (dir.handle == INVALID_HANDLE_VALUE)
            return;
        FindClose(cast(HANDLE)dir.handle);
        dir.handle = INVALID_HANDLE_VALUE;
        dir.pending = false;
    }
    else version (Posix)
    {
        if (dir.dir is null)
            return;
        closedir(dir.dir);
        dir.dir = null;
    }
    else version (HasFileBackend)
    {
        if (dir.fd < 0)
            return;
        static foreach (i, B; FileBackends)
        {
            if (dir.backend == i)
            {
                static if (B.flat)
                    B.scan_close(dir.fd);
                else
                    B.dir_close(dir.fd);
            }
        }
        dir.fd = -1;
        dir.backend = ubyte.max;
    }
}

bool is_open(ref const Directory dir)
{
    version (Windows)
        return dir.handle != INVALID_HANDLE_VALUE;
    else version (Posix)
        return dir.dir !is null;
    else version (HasFileBackend)
        return dir.fd >= 0;
    else
        return false;
}

Result open(ref File file, const(char)[] path, FileOpenMode mode, FileOpenFlags openFlags = FileOpenFlags.None)
{
    version (Windows)
    {
        assert(file.handle == INVALID_HANDLE_VALUE);

        uint dwDesiredAccess = 0;
        uint dwShareMode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        uint dwCreationDisposition = 0;

        switch (mode)
        {
            case FileOpenMode.Write:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadWrite:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadExisting:
                dwDesiredAccess = GENERIC_READ;
                dwCreationDisposition = OPEN_EXISTING;
                break;
            case FileOpenMode.ReadWriteExisting:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_EXISTING;
                break;
            case FileOpenMode.WriteTruncate:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = CREATE_ALWAYS;
                break;
            case FileOpenMode.ReadWriteTruncate:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = CREATE_ALWAYS;
                break;
            case FileOpenMode.WriteAppend:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadWriteAppend:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            default:
                return InternalResult.invalid_parameter;
        }

        uint dwFlagsAndAttributes = FILE_ATTRIBUTE_NORMAL;
        if (openFlags & FileOpenFlags.NoBuffering)
            dwFlagsAndAttributes |= FILE_FLAG_NO_BUFFERING;
        if (openFlags & FileOpenFlags.RandomAccess)
            dwFlagsAndAttributes |= FILE_FLAG_RANDOM_ACCESS;
        else if (openFlags & FileOpenFlags.Sequential)
            dwFlagsAndAttributes |= FILE_FLAG_SEQUENTIAL_SCAN;

        file.handle = CreateFileW(path.twstringz, dwDesiredAccess, dwShareMode, null, dwCreationDisposition, dwFlagsAndAttributes, null);
        if (file.handle == INVALID_HANDLE_VALUE)
            return getlasterror_result();

        if (mode == FileOpenMode.WriteAppend || mode == FileOpenMode.ReadWriteAppend)
            SetFilePointer(file.handle, 0, null, FILE_END);
    }
    else version (Posix)
    {
        assert(file.fd == -1);

        int flags;
        switch (mode)
        {
            case FileOpenMode.Write:
                flags = O_WRONLY | O_CREAT;
                break;
            case FileOpenMode.ReadWrite:
                flags = O_RDWR | O_CREAT;
                break;
            case FileOpenMode.ReadExisting:
                flags = O_RDONLY;
                break;
            case FileOpenMode.ReadWriteExisting:
                flags = O_RDWR;
                break;
            case FileOpenMode.WriteTruncate:
                flags = O_WRONLY | O_CREAT | O_TRUNC;
                break;
            case FileOpenMode.ReadWriteTruncate:
                flags = O_RDWR | O_CREAT | O_TRUNC;
                break;
            case FileOpenMode.WriteAppend:
                flags = O_WRONLY | O_APPEND | O_CREAT;
                break;
            case FileOpenMode.ReadWriteAppend:
                flags = O_RDWR | O_APPEND | O_CREAT;
                break;
            default:
                return InternalResult.invalid_parameter;
        }

        flags |= O_CLOEXEC;

        version (Darwin) {} else {
            if (openFlags & FileOpenFlags.NoBuffering)
                flags |= O_DIRECT;
        }

        int fd = urt.internal.sys.posix.open(path.tstringz, flags, 0b110_110_110);
        if (fd < 0)
            return errno_result();
        file.fd = fd;

        version (Darwin) {
            if (openFlags & FileOpenFlags.NoBuffering)
                fcntl(fd, F_NOCACHE, 1);
        }

        int advice = POSIX_FADV_NORMAL;
        if (openFlags & FileOpenFlags.RandomAccess)
            advice = POSIX_FADV_RANDOM;
        else if (openFlags & FileOpenFlags.Sequential)
            advice = POSIX_FADV_SEQUENTIAL;
        if (advice != POSIX_FADV_NORMAL)
        {
            // Not checking the error case because the file should continue
            // to operate correctly even if this fails.
            posix_fadvise(fd, 0, 0, advice);
        }

        if (mode == FileOpenMode.WriteAppend || mode == FileOpenMode.ReadWriteAppend)
            lseek(file.fd, 0, SEEK_END);
    }
    else version (HasFileBackend)
    {
        const bool write = mode != FileOpenMode.ReadExisting;
        const bool truncate = mode == FileOpenMode.WriteTruncate || mode == FileOpenMode.ReadWriteTruncate;
        const bool create = mode != FileOpenMode.ReadExisting && mode != FileOpenMode.ReadWriteExisting;

        // Prefer the backend already holding it, so writes land on the copy
        // that reads will find.
        static foreach (i, B; FileBackends)
        {
            if (file.fd < 0 && B.exists(path))
            {
                int fd = B.open(path, write, truncate);
                if (fd >= 0)
                {
                    file.fd = fd;
                    file.backend = i;
                }
            }
        }
        if (file.fd < 0 && create)
        {
            int fd = FileBackends[0].open(path, true, truncate);
            if (fd >= 0)
            {
                file.fd = fd;
                file.backend = 0;
            }
        }
        if (file.fd < 0)
        {
            static foreach (B; FileBackends)
            {
                if (B.available())
                    return InternalResult.failed;
            }
            return InternalResult.unsupported;
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform

    return Result.success;
}

bool is_open(ref const File file)
{
    version (Windows)
        return file.handle != INVALID_HANDLE_VALUE;
    else version (Posix)
        return file.fd != -1;
    else version (HasFileBackend)
        return file.fd >= 0;
    else
        return false;
}

void close(ref File file)
{
    version (Windows)
    {
        if (file.handle == INVALID_HANDLE_VALUE)
            return;
        CloseHandle(file.handle);
        file.handle = INVALID_HANDLE_VALUE;
    }
    else version (Posix)
    {
        if (file.fd == -1)
            return;
        urt.internal.sys.posix.close(file.fd);
        file.fd = -1;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
                B.close(file.fd);
        }
        file.fd = -1;
        file.backend = ubyte.max;
    }
}

ulong get_size(ref const File file)
{
    version (Windows)
    {
        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(cast(void*)file.handle, &fileSize))
            return 0;
        return fileSize.QuadPart;
    }
    else version (Posix)
    {
        stat_t fs;
        if (fstat(file.fd, &fs))
            return 0;
        return fs.st_size;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return 0;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
                return B.size(file.fd);
        }
        return 0;
    }
    else
        return 0;
}

Result set_size(ref File file, ulong size)
{
    version (Windows)
    {
        ulong curPos = file.get_pos();
        scope(exit)
            file.set_pos(curPos);

        ulong curFileSize = file.get_size();
        if (size > curFileSize)
        {
            if (!file.set_pos(curFileSize))
                return getlasterror_result();

            // zero-fill
            char[4096] buf = void;
            ulong n = size - curFileSize;
            uint bufSize = buf.sizeof;
            if (bufSize > n)
                bufSize = cast(uint)n;
            buf[0..bufSize] = 0;

            while (n)
            {
                uint bytesToWrite = n >= buf.sizeof ? buf.sizeof : cast(uint)n;
                size_t bytesWritten;
                Result result = file.write(buf[0..bytesToWrite], bytesWritten);
                if (!result)
                    return result;
                n -= bytesWritten;
            }
        }
        else
        {
            if (!file.set_pos(size))
                return getlasterror_result();
            if (!SetEndOfFile(file.handle))
                return getlasterror_result();
        }
    }
    else version (Posix)
    {
        if (ftruncate(file.fd, size))
            return errno_result();
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i && !B.set_size(file.fd, size))
                return InternalResult.failed;
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

ulong get_pos(ref const File file)
{
    version (Windows)
    {
        LARGE_INTEGER liDistanceToMove = void;
        LARGE_INTEGER liResult = void;
        liDistanceToMove.QuadPart = 0;
        SetFilePointerEx(cast(HANDLE)file.handle, liDistanceToMove, &liResult, FILE_CURRENT);
        return liResult.QuadPart;
    }
    else version (Posix)
        return lseek(file.fd, 0, SEEK_CUR);
    else version (HasFileBackend)
    {
        if (file.fd >= 0)
        {
            static foreach (i, B; FileBackends)
            {
                if (file.backend == i)
                {
                    long pos = B.seek(file.fd, 0, seek_cur);
                    return pos < 0 ? 0 : cast(ulong)pos;
                }
            }
        }
        return 0;
    }
    else
        return 0;
}

Result set_pos(ref File file, ulong offset)
{
    version (Windows)
    {
        LARGE_INTEGER liDistanceToMove = void;
        liDistanceToMove.QuadPart = offset;
        if (!SetFilePointerEx(file.handle, liDistanceToMove, null, FILE_BEGIN))
            return getlasterror_result();
    }
    else version (Posix)
    {
        off_t rc = lseek(file.fd, offset, SEEK_SET);
        if (rc < 0)
            return errno_result();
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i && B.seek(file.fd, cast(long)offset, seek_set) < 0)
                return InternalResult.failed;
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result read(ref File file, void[] buffer, out size_t bytesRead)
{
    version (Windows)
    {
        import urt.util : min;

        DWORD dwBytesRead;
        if (!ReadFile(file.handle, buffer.ptr, cast(uint)min(buffer.length, uint.max), &dwBytesRead, null))
        {
            DWORD lastError = GetLastError();
            return (lastError == ERROR_BROKEN_PIPE) ? Result.success : win32_result(lastError);
        }
        bytesRead = dwBytesRead;
    }
    else version (Posix)
    {
        ptrdiff_t n = urt.internal.sys.posix.read(file.fd, buffer.ptr, buffer.length);
        if (n < 0)
            return errno_result();
        bytesRead = n;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
            {
                ptrdiff_t n = B.read(file.fd, buffer);
                if (n < 0)
                    return InternalResult.failed;
                bytesRead = n;
            }
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result read_at(ref File file, void[] buffer, ulong offset, out size_t bytesRead)
{
    version (Windows)
    {
        if (buffer.length > DWORD.max)
            return InternalResult.invalid_parameter;

        OVERLAPPED o;
        o.Offset = cast(DWORD)offset;
        o.OffsetHigh = cast(DWORD)(offset >> 32);

        DWORD dwBytesRead;
        if (!ReadFile(file.handle, buffer.ptr, cast(DWORD)buffer.length, &dwBytesRead, &o))
        {
            Result error = getlasterror_result();
            if (error.system_code != ERROR_HANDLE_EOF)
                return error;
        }
        bytesRead = dwBytesRead;
    }
    else version (Posix)
    {
        ssize_t n = pread(file.fd, buffer.ptr, buffer.length, offset);
        if (n < 0)
            return errno_result();
        bytesRead = n;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
            {
                // no pread; emulate it and put the position back
                long restore = B.seek(file.fd, 0, seek_cur);
                if (restore < 0 || B.seek(file.fd, cast(long)offset, seek_set) < 0)
                    return InternalResult.failed;
                ptrdiff_t n = B.read(file.fd, buffer);
                B.seek(file.fd, restore, seek_set);
                if (n < 0)
                    return InternalResult.failed;
                bytesRead = n;
            }
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result write(ref File file, const(void)[] data, out size_t bytesWritten)
{
    version (Windows)
    {
        DWORD dwBytesWritten;
        if (!WriteFile(file.handle, data.ptr, cast(uint)data.length, &dwBytesWritten, null))
            return getlasterror_result();
        bytesWritten = dwBytesWritten;
    }
    else version (Posix)
    {
        ptrdiff_t n = urt.internal.sys.posix.write(file.fd, data.ptr, data.length);
        if (n < 0)
            return errno_result();
        bytesWritten = n;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
            {
                ptrdiff_t n = B.write(file.fd, data);
                if (n < 0)
                    return InternalResult.failed;
                bytesWritten = n;
            }
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result write_at(ref File file, const(void)[] data, ulong offset, out size_t bytesWritten)
{
    version (Windows)
    {
        if (data.length > DWORD.max)
            return InternalResult.invalid_parameter;

        OVERLAPPED o;
        o.Offset = cast(DWORD)offset;
        o.OffsetHigh = cast(DWORD)(offset >> 32);

        DWORD dwBytesWritten;
        if (!WriteFile(file.handle, data.ptr, cast(DWORD)data.length, &dwBytesWritten, &o))
            return getlasterror_result();
        bytesWritten = dwBytesWritten;
    }
    else version (Posix)
    {
        ptrdiff_t n = pwrite(file.fd, data.ptr, data.length, offset);
        if (n < 0)
            return errno_result();
        bytesWritten = n;
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i)
            {
                // no pwrite; emulate it and put the position back
                long restore = B.seek(file.fd, 0, seek_cur);
                if (restore < 0 || B.seek(file.fd, cast(long)offset, seek_set) < 0)
                    return InternalResult.failed;
                ptrdiff_t n = B.write(file.fd, data);
                B.seek(file.fd, restore, seek_set);
                if (n < 0)
                    return InternalResult.failed;
                bytesWritten = n;
            }
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

Result flush(ref File file)
{
    version (Windows)
    {
        if (!FlushFileBuffers(file.handle))
            return getlasterror_result();
    }
    else version (Posix)
    {
        if (fsync(file.fd))
            return errno_result();
    }
    else version (HasFileBackend)
    {
        if (file.fd < 0)
            return InternalResult.invalid_parameter;
        static foreach (i, B; FileBackends)
        {
            if (file.backend == i && !B.sync(file.fd))
                return InternalResult.failed;
        }
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}

FileResult file_result(Result result)
{
    version (Windows)
    {
        switch (result.system_code)
        {
            case ERROR_SUCCESS:         return FileResult.Success;
            case ERROR_DISK_FULL:       return FileResult.DiskFull;
            case ERROR_ACCESS_DENIED:   return FileResult.AccessDenied;
            case ERROR_ALREADY_EXISTS:  return FileResult.AlreadyExists;
            case ERROR_FILE_NOT_FOUND:  return FileResult.NotFound;
            case ERROR_PATH_NOT_FOUND:  return FileResult.NotFound;
            case ERROR_NO_DATA:         return FileResult.NoData;
            default:                    return FileResult.Failure;
        }
    }
    else version (Posix)
    {
        static assert(EAGAIN == EWOULDBLOCK, "Expect EGAIN and EWOULDBLOCK are the same value");
        switch (result.system_code)
        {
            case 0:         return FileResult.Success;
            case ENOSPC:    return FileResult.DiskFull;
            case EACCES:    return FileResult.AccessDenied;
            case EEXIST:    return FileResult.AlreadyExists;
            case ENOENT:    return FileResult.NotFound;
            case EAGAIN:    return FileResult.NoData;
            default:        return FileResult.Failure;
        }
    }
    else
        return FileResult.Failure; // no filesystem on this platform
}

Result get_temp_filename(ref char[] buffer, const(char)[] dstDir, const(char)[] prefix)
{
    version (Windows)
    {
        import urt.mem : wcslen;

        wchar[MAX_PATH] tmp = void;
        if (!GetTempFileNameW(dstDir.twstringz, prefix.twstringz, 0, tmp.ptr))
            return getlasterror_result();
        size_t resLen = wcslen(tmp.ptr);
        resLen = tmp[((dstDir.length == 0 && tmp[0] == '\\') ? 1 : 0)..resLen].uni_convert(buffer);
        if (resLen == 0)
        {
            DeleteFileW(tmp.ptr);
            return InternalResult.buffer_too_small;
        }
        buffer = buffer[0 .. resLen];
    }
    else version (Posix)
    {
        // Construct a format string which will be the supplied dir with prefix and 8 generated random characters
        char[] fn = cast(char[])tconcat(dstDir, (dstDir.length && dstDir[$-1] != '/') ? "/" : "", prefix, "XXXXXX\0");
        File file;
        file.fd = mkstemp(fn.ptr);
        if (file.fd == -1)
            return errno_result();
        Result r = get_path(file, buffer);
        urt.internal.sys.posix.close(file.fd);
        return r;
    }
    else
        return InternalResult.unsupported; // no filesystem on this platform
    return Result.success;
}


version (FreeStanding) {}
else unittest
{
    import urt.string;

    char[320] buffer = void;
    char[] filename = buffer[];
    assert(get_temp_filename(filename, "", "pre"));

    File file;
    assert(file.open(filename, FileOpenMode.ReadWriteTruncate));
    assert(file.is_open);

    char[320] buffer2 = void;
    char[] path = buffer2[];
    assert(file.get_path(path));
    assert(path.endsWith(filename));

    file.close();
    assert(!file.is_open);

    assert(filename.delete_file());

    // create a temp file with known content
    filename = buffer[];
    assert(get_temp_filename(filename, "", "stat_test"));

    assert(file.open(filename, FileOpenMode.WriteTruncate));

    // write exactly 42 bytes
    ubyte[42] data;
    size_t written;
    assert(file.write(data[], written));
    assert(written == 42);

    // get_size exercises fstat + st_size
    assert(file.get_size() == 42);

    // set_size exercises ftruncate, then fstat again
    assert(file.set_size(100));
    assert(file.get_size() == 100);

    file.close();

    // file_exists exercises stat + S_ISREG + st_mode
    assert(file_exists(filename));

    // clean up and verify
    assert(filename.delete_file());
    assert(!file_exists(filename));
}

version (FreeStanding) {}
else unittest
{
    import urt.mem.temp : tconcat;
    import urt.string;

    // A temp *file* name is the only unique name on offer, so borrow one and
    // hang a directory off it. "." rather than "" because with no directory
    // Windows creates the file at the drive root and hands back a relative
    // path, which then names nothing.
    char[320] buffer = void;
    char[] temp_name = buffer[];
    assert(get_temp_filename(temp_name, ".", "dirtest"));
    const(char)[] dir_path = tconcat(temp_name, ".dir");
    assert(create_directory(dir_path));

    assert(save_file(tconcat(dir_path, "/one.txt"), cast(const(void)[])"12345"));
    assert(save_file(tconcat(dir_path, "/two.txt"), cast(const(void)[])"12345678"));
    assert(create_directory(tconcat(dir_path, "/sub")));

    Directory dir;
    assert(dir.open(dir_path));
    assert(dir.is_open);

    size_t files, dirs;
    bool saw_one, saw_two, saw_sub;
    DirEntry entry;
    while (dir.read(entry))
    {
        // "." and ".." are the walker's business, never the caller's
        assert(entry.name != "." && entry.name != "..");
        if (entry.is_directory)
        {
            ++dirs;
            saw_sub |= entry.name == "sub";
        }
        else
        {
            ++files;
            if (entry.name == "one.txt")
            {
                saw_one = true;
                assert(entry.size == 5);
            }
            else if (entry.name == "two.txt")
            {
                saw_two = true;
                assert(entry.size == 8);
            }
        }
    }
    assert(files == 2 && dirs == 1);
    assert(saw_one && saw_two && saw_sub);

    dir.close();
    assert(!dir.is_open);

    // Reading a closed walk ends rather than faulting, and so does a walk that
    // never opened.
    assert(!dir.read(entry));
    Directory missing;
    assert(!missing.open(tconcat(dir_path, "/nope")));
    assert(!missing.read(entry));

    assert(tconcat(dir_path, "/one.txt").delete_file());
    assert(tconcat(dir_path, "/two.txt").delete_file());
    assert(temp_name.delete_file());
}
