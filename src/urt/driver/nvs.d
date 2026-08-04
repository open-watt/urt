module urt.driver.nvs;

import urt.result : Result, SizeResult;
import urt.variant : Variant;

nothrow @nogc:


enum NvsOpenMode : ubyte
{
    read_only,
    read_write,
}

enum NvsError : uint
{
    none,
    failed,
    unsupported,
    not_initialized,
    not_found,
    type_mismatch,
    read_only,
    not_enough_space,
    invalid_name,
    invalid_handle,
    write_failed,
    invalid_length,
    value_too_long,
    partition_not_found,
    incompatible_version,
    no_memory,
    invalid_parameter,
    already_open,
    corrupt,
}

struct Nvs
{
    uint driver_handle;
}

version (Espressif)
{
    enum bool has_nvs = true;
    enum size_t nvs_max_namespace_length = 15;
    enum size_t nvs_max_key_length = 15;
    private import urt.driver.esp32.nvs;
}
else
{
    enum bool has_nvs = false;
    enum size_t nvs_max_namespace_length = 0;
    enum size_t nvs_max_key_length = 0;
}

bool is_open(ref const Nvs nvs)
{
    return nvs.driver_handle != 0;
}

NvsError nvs_error(Result result)
{
    return cast(NvsError)result.system_code;
}

Result nvs_open(ref Nvs nvs, const(char)[] namespace_, NvsOpenMode mode = NvsOpenMode.read_write)
{
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
    {
        if (!valid_name(namespace_, nvs_max_namespace_length))
            return nvs_result(NvsError.invalid_name);
        if (nvs.is_open)
            return nvs_result(NvsError.already_open);
        if (mode > NvsOpenMode.read_write)
            return nvs_result(NvsError.invalid_parameter);
        return nvs_hw_open(nvs, namespace_, mode);
    }
}

void nvs_close(ref Nvs nvs)
{
    static if (has_nvs)
        if (nvs.is_open)
            nvs_hw_close(nvs);
    nvs.driver_handle = 0;
}

Result nvs_commit(ref Nvs nvs)
{
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
        return nvs.is_open ? nvs_hw_commit(nvs) : nvs_result(NvsError.invalid_handle);
}

Result nvs_get(ref Nvs nvs, const(char)[] key, out Variant value)
{
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
    {
        Result result = validate_key(nvs, key);
        return result ? nvs_hw_get(nvs, key, value) : result;
    }
}

Result nvs_set(ref Nvs nvs, const(char)[] key, ref const Variant value)
{
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
    {
        Result result = validate_key(nvs, key);
        return result ? nvs_hw_set(nvs, key, value) : result;
    }
}

Result nvs_get_size(ref Nvs nvs, const(char)[] key, out size_t length)
{
    length = 0;
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
    {
        Result result = validate_key(nvs, key);
        return result ? nvs_hw_get_size(nvs, key, length) : result;
    }
}

SizeResult nvs_read(ref Nvs nvs, const(char)[] key, void[] value)
{
    static if (!has_nvs)
        return SizeResult(nvs_result(NvsError.unsupported));
    else
    {
        Result result = validate_key(nvs, key);
        if (!result)
            return SizeResult(result);
        return nvs_hw_read(nvs, key, value);
    }
}

Result nvs_write(ref Nvs nvs, const(char)[] key, const(void)[] value)
{
    static if (!has_nvs)
        return nvs_result(NvsError.unsupported);
    else
    {
        Result result = validate_key(nvs, key);
        return result ? nvs_hw_write(nvs, key, value) : result;
    }
}


private:

Result nvs_result(NvsError error)
{
    return Result(cast(uint)error);
}

Result validate_key(ref const Nvs nvs, const(char)[] key)
{
    if (!valid_name(key, nvs_max_key_length))
        return nvs_result(NvsError.invalid_name);
    return nvs.is_open ? Result.success : nvs_result(NvsError.invalid_handle);
}

bool valid_name(const(char)[] name, size_t max_length)
{
    if (name.length == 0 || name.length > max_length)
        return false;
    foreach (char c; name)
        if (c == 0)
            return false;
    return true;
}

unittest
{
    assert(nvs_error(Result.success) == NvsError.none);
    assert(valid_name("openwatt", 15));
    assert(!valid_name("", 15));
    assert(!valid_name("0123456789abcdef", 15));
    assert(!valid_name("bad\0name", 15));
}
