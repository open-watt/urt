module urt.fs.spiffs;

version (UseSpiffs):

nothrow @nogc:


enum SpiffsFormatState : ubyte
{
    idle,
    running,
    complete,
    failed,
}

bool format_begin()
    => urt_spiffs_format_begin() == 0;

SpiffsFormatState format_state()
    => cast(SpiffsFormatState)urt_spiffs_format_status();


// Flat namespace: the whole path is the object name, so paths round trip but
// there is nothing to enumerate, and SPIFFS_OBJ_NAME_LEN caps them at 31 chars.
struct SpiffsBackend
{
static nothrow @nogc:

    enum name = "spiffs";

    // False when the partition is absent or unformatted, which lets urt.file
    // separate "no filesystem" from "the operation failed".
    bool available()
        => urt_spiffs_available() != 0;

    int last_error()
        => urt_spiffs_last_error();

    bool info(out ulong total, out ulong used)
        => urt_spiffs_info(&total, &used) == 0;

    bool exists(const(char)[] path)
        => urt_spiffs_exists(path.ptr, path.length) != 0;

    bool stat(const(char)[] path, out ulong size)
        => urt_spiffs_stat(path.ptr, path.length, &size) == 0;

    bool remove(const(char)[] path)
        => urt_spiffs_unlink(path.ptr, path.length) == 0;

    bool rename(const(char)[] from, const(char)[] to)
        => urt_spiffs_rename(from.ptr, from.length, to.ptr, to.length) == 0;

    int open(const(char)[] path, bool write, bool truncate)
        => urt_spiffs_open(path.ptr, path.length, write, truncate);

    ptrdiff_t read(int fd, void[] buffer)
        => urt_spiffs_read(fd, buffer.ptr, buffer.length);

    ptrdiff_t write(int fd, const(void)[] data)
        => urt_spiffs_write(fd, data.ptr, data.length);

    void close(int fd)
        => urt_spiffs_close(fd);

    ulong size(int fd)
        => urt_spiffs_size(fd);

    long seek(int fd, long offset, int whence)
        => urt_spiffs_seek(fd, offset, whence);

    bool set_size(int fd, ulong length)
        => urt_spiffs_truncate(fd, length) == 0;

    bool sync(int fd)
        => urt_spiffs_sync(fd) == 0;
}


private extern(C)
{
    int urt_spiffs_format_begin();
    int urt_spiffs_format_status();
    int urt_spiffs_available();
    int urt_spiffs_last_error();
    int urt_spiffs_info(ulong* total, ulong* used);
    int urt_spiffs_exists(const(char)* path, size_t path_len);
    int urt_spiffs_stat(const(char)* path, size_t path_len, ulong* size);
    int urt_spiffs_unlink(const(char)* path, size_t path_len);
    int urt_spiffs_rename(const(char)* from, size_t from_len, const(char)* to, size_t to_len);
    int urt_spiffs_open(const(char)* path, size_t path_len, bool write, bool truncate);
    ptrdiff_t urt_spiffs_read(int fd, void* buffer, size_t length);
    ptrdiff_t urt_spiffs_write(int fd, const(void)* data, size_t length);
    void urt_spiffs_close(int fd);
    ulong urt_spiffs_size(int fd);
    long urt_spiffs_seek(int fd, long offset, int whence);
    int urt_spiffs_truncate(int fd, ulong length);
    int urt_spiffs_sync(int fd);
}
