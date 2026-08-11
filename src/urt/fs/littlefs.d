module urt.fs.littlefs;

version (UseLittleFS):

nothrow @nogc:


enum LittleFsFormatState : ubyte
{
    idle,
    running,
    complete,
    failed,
}

bool format_begin()
    => urt_littlefs_format_begin() == 0;

LittleFsFormatState format_state()
    => cast(LittleFsFormatState)urt_littlefs_format_status();


// Real directories and atomic rename-over, so unlike the SPIFFS backend paths
// are not flattened and a swap does not need a delete first.
struct LittleFsBackend
{
static nothrow @nogc:

    enum name = "littlefs";

    bool available()
        => urt_littlefs_available() != 0;

    int last_error()
        => urt_littlefs_last_error();

    int open_handles()
        => urt_littlefs_open_handles();

    bool info(out ulong total, out ulong used)
        => urt_littlefs_info(&total, &used) == 0;

    bool exists(const(char)[] path)
        => urt_littlefs_exists(path.ptr, path.length) != 0;

    bool stat(const(char)[] path, out ulong size)
        => urt_littlefs_stat(path.ptr, path.length, &size) == 0;

    bool remove(const(char)[] path)
        => urt_littlefs_unlink(path.ptr, path.length) == 0;

    bool rename(const(char)[] from, const(char)[] to)
        => urt_littlefs_rename(from.ptr, from.length, to.ptr, to.length) == 0;

    int open(const(char)[] path, bool write, bool truncate)
        => urt_littlefs_open(path.ptr, path.length, write, truncate);

    ptrdiff_t read(int fd, void[] buffer)
        => urt_littlefs_read(fd, buffer.ptr, buffer.length);

    ptrdiff_t write(int fd, const(void)[] data)
        => urt_littlefs_write(fd, data.ptr, data.length);

    void close(int fd)
        => urt_littlefs_close(fd);

    ulong size(int fd)
        => urt_littlefs_size(fd);

    long seek(int fd, long offset, int whence)
        => urt_littlefs_seek(fd, offset, whence);

    bool set_size(int fd, ulong length)
        => urt_littlefs_truncate(fd, length) == 0;

    bool sync(int fd)
        => urt_littlefs_sync(fd) == 0;

    int dir_open(const(char)[] path)
        => urt_littlefs_dir_open(path.ptr, path.length);

    ptrdiff_t dir_read(int fd, char[] name, out ulong size, out bool is_dir)
    {
        int dir;
        ptrdiff_t r = urt_littlefs_dir_read(fd, name.ptr, name.length, &size, &dir);
        is_dir = dir != 0;
        return r;
    }

    void dir_close(int fd)
        => urt_littlefs_dir_close(fd);
}


private extern(C)
{
    int urt_littlefs_format_begin();
    int urt_littlefs_format_status();
    int urt_littlefs_available();
    int urt_littlefs_last_error();
    int urt_littlefs_open_handles();
    int urt_littlefs_info(ulong* total, ulong* used);
    int urt_littlefs_exists(const(char)* path, size_t path_len);
    int urt_littlefs_stat(const(char)* path, size_t path_len, ulong* size);
    int urt_littlefs_unlink(const(char)* path, size_t path_len);
    int urt_littlefs_rename(const(char)* from, size_t from_len, const(char)* to, size_t to_len);
    int urt_littlefs_open(const(char)* path, size_t path_len, bool write, bool truncate);
    ptrdiff_t urt_littlefs_read(int fd, void* buffer, size_t length);
    ptrdiff_t urt_littlefs_write(int fd, const(void)* data, size_t length);
    void urt_littlefs_close(int fd);
    ulong urt_littlefs_size(int fd);
    long urt_littlefs_seek(int fd, long offset, int whence);
    int urt_littlefs_truncate(int fd, ulong length);
    int urt_littlefs_sync(int fd);
    int urt_littlefs_dir_open(const(char)* path, size_t path_len);
    ptrdiff_t urt_littlefs_dir_read(int fd, char* name, size_t name_len, ulong* size, int* is_dir);
    void urt_littlefs_dir_close(int fd);
}
