module urt.driver.esp32.nvs;

import urt.driver.nvs : Nvs, NvsError, NvsOpenMode;
import urt.endian : littleEndianToNative, nativeToLittleEndian;
import urt.mem.allocator : defaultAllocator;
import urt.result : Result, SizeResult;
import urt.si.unit : ScaledUnit;
import urt.typereg : find_type_by_name, find_type_details, TypeDetails;
import urt.variant : Variant;

nothrow @nogc:


Result nvs_hw_open(ref Nvs nvs, const(char)[] namespace_, NvsOpenMode mode)
{
    char[16] name = void;
    terminate(namespace_, name);
    uint handle;
    int result = esp_nvs_open(name.ptr, cast(int)mode, &handle);
    if (result == ESP_OK)
        nvs.driver_handle = handle;
    return map_result(result);
}

void nvs_hw_close(ref Nvs nvs)
{
    esp_nvs_close(nvs.driver_handle);
}

Result nvs_hw_commit(ref Nvs nvs)
{
    return map_result(esp_nvs_commit(nvs.driver_handle));
}

Result nvs_hw_get(ref Nvs nvs, const(char)[] key, ref Variant value)
{
    char[16] name = void;
    terminate(key, name);

    int raw_type;
    Result result = map_result(esp_nvs_find_key(nvs.driver_handle, name.ptr, &raw_type));
    if (!result)
        return result;

    switch (cast(NvsType)raw_type)
    {
        case NvsType.i8:  return get_integer!byte(nvs.driver_handle, name, value);
        case NvsType.u8:  return get_integer!ubyte(nvs.driver_handle, name, value);
        case NvsType.i16: return get_integer!short(nvs.driver_handle, name, value);
        case NvsType.u16: return get_integer!ushort(nvs.driver_handle, name, value);
        case NvsType.i32: return get_integer!int(nvs.driver_handle, name, value);
        case NvsType.u32: return get_integer!uint(nvs.driver_handle, name, value);
        case NvsType.i64: return get_integer!long(nvs.driver_handle, name, value);
        case NvsType.u64: return get_integer!ulong(nvs.driver_handle, name, value);
        case NvsType.string_: return get_string(nvs.driver_handle, name, value);
        case NvsType.blob: return get_blob(nvs.driver_handle, name, value);
        default: return nvs_result(NvsError.type_mismatch);
    }
}

Result nvs_hw_set(ref Nvs nvs, const(char)[] key, ref const Variant value)
{
    char[16] name = void;
    terminate(key, name);

    if (value.isNull)
        return set_typed_blob(nvs.driver_handle, name, BlobType.null_, 0, null);
    if (value.isBool)
        return set_typed_blob(nvs.driver_handle, name, BlobType.boolean, value.asBool, null);
    if (value.isString)
        return set_typed_blob(nvs.driver_handle, name, BlobType.string_, 0, value.asString);
    if (value.isBuffer)
        return map_result(esp_nvs_set_blob(nvs.driver_handle, name.ptr, value.asBuffer.ptr, value.asBuffer.length));
    if (!value.isNumber)
        return value.isUserType ? set_user(nvs.driver_handle, name, value) : nvs_result(NvsError.unsupported);
    if (value.is_enum)
        return nvs_result(NvsError.unsupported);
    if (value.isQuantity)
        return set_quantity(nvs.driver_handle, name, value);
    if (value.isDouble)
        return value.isFloat ? set_float(nvs.driver_handle, name, value.asFloat)
                             : set_float(nvs.driver_handle, name, value.asDouble);
    return value.isUlong ? set_integer(nvs.driver_handle, name, value.asUlong)
                         : set_integer(nvs.driver_handle, name, value.asLong);
}

Result nvs_hw_get_size(ref Nvs nvs, const(char)[] key, out size_t length)
{
    char[16] name = void;
    terminate(key, name);
    return map_result(esp_nvs_get_blob(nvs.driver_handle, name.ptr, null, &length));
}

SizeResult nvs_hw_read(ref Nvs nvs, const(char)[] key, void[] value)
{
    char[16] name = void;
    terminate(key, name);
    size_t length = value.length;
    void* destination = value.length ? value.ptr : null;
    Result result = map_result(esp_nvs_get_blob(nvs.driver_handle, name.ptr, destination, &length));
    return result ? SizeResult(length) : SizeResult(result);
}

Result nvs_hw_write(ref Nvs nvs, const(char)[] key, const(void)[] value)
{
    char[16] name = void;
    terminate(key, name);
    return map_result(esp_nvs_set_blob(nvs.driver_handle, name.ptr, value.ptr, value.length));
}


private:

enum NvsType : ubyte
{
    u8 = 0x01,
    u16 = 0x02,
    u32 = 0x04,
    u64 = 0x08,
    i8 = 0x11,
    i16 = 0x12,
    i32 = 0x14,
    i64 = 0x18,
    string_ = 0x21,
    blob = 0x42,
    f32 = 0x44,
    f64 = 0x48,
}

enum BlobType : ubyte
{
    boolean,
    float_,
    string_,
    quantity,
    user,
    null_,
}

enum ubyte blob_guard = 0xa5;
enum size_t blob_header_length = 8;

Result get_integer(T)(uint handle, ref const char[16] key, ref Variant value)
{
    T number;
    Result result = get_native(handle, key.ptr, number);
    if (result)
        value = Variant(number);
    return result;
}

Result get_string(uint handle, ref const char[16] key, ref Variant value)
{
    size_t length;
    Result result = map_result(esp_nvs_get_str(handle, key.ptr, null, &length));
    if (!result)
        return result;
    if (length == 0)
        return nvs_result(NvsError.corrupt);

    void[] bytes = defaultAllocator.alloc(length);
    if (!bytes.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) defaultAllocator.free(bytes);

    result = map_result(esp_nvs_get_str(handle, key.ptr, cast(char*)bytes.ptr, &length));
    if (!result)
        return result;
    if (length == 0 || (cast(char*)bytes.ptr)[length - 1] != 0)
        return nvs_result(NvsError.corrupt);
    value = Variant(cast(const(char)[])bytes[0 .. length - 1]);
    return Result.success;
}

Result get_blob(uint handle, ref const char[16] key, ref Variant value)
{
    size_t length;
    Result result = map_result(esp_nvs_get_blob(handle, key.ptr, null, &length));
    if (!result)
        return result;
    if (length == 0)
    {
        value = Variant();
        return Result.success;
    }

    void[] bytes = defaultAllocator.alloc(length);
    if (!bytes.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) defaultAllocator.free(bytes);

    result = map_result(esp_nvs_get_blob(handle, key.ptr, bytes.ptr, &length));
    if (!result)
        return result;
    if (length != bytes.length)
        return nvs_result(NvsError.corrupt);
    if (!valid_header(bytes))
    {
        value = Variant(cast(const(void)[])bytes);
        return Result.success;
    }

    const(ubyte)[] payload = cast(const(ubyte)[])bytes[blob_header_length .. $];
    ubyte kind = (cast(const(ubyte)[])bytes)[4];
    ubyte format = (cast(const(ubyte)[])bytes)[5];
    switch (cast(BlobType)kind)
    {
        case BlobType.null_:
            if (payload.length != 0 || format)
                return nvs_result(NvsError.corrupt);
            value = Variant();
            return Result.success;
        case BlobType.boolean:
            if (payload.length != 0 || format > 1)
                return nvs_result(NvsError.corrupt);
            value = Variant(format != 0);
            return Result.success;
        case BlobType.float_:
            return get_float(format, payload, value);
        case BlobType.string_:
            if (format)
                return nvs_result(NvsError.corrupt);
            value = Variant(cast(const(char)[])payload);
            return Result.success;
        case BlobType.quantity:
            return get_quantity(format, payload, value);
        case BlobType.user:
            return get_user(format, payload, value);
        default:
            return nvs_result(NvsError.incompatible_version);
    }
}

Result set_integer(T)(uint handle, ref const char[16] key, T number)
{
    static if (is(T == long))
    {
        if (number < 0)
        {
            if (number >= byte.min)
                return set_native(handle, key.ptr, cast(byte)number);
            if (number >= short.min)
                return set_native(handle, key.ptr, cast(short)number);
            if (number >= int.min)
                return set_native(handle, key.ptr, cast(int)number);
            return set_native(handle, key.ptr, number);
        }
    }

    ulong unsigned_number = cast(ulong)number;
    if (unsigned_number <= ubyte.max)
        return set_native(handle, key.ptr, cast(ubyte)unsigned_number);
    if (unsigned_number <= ushort.max)
        return set_native(handle, key.ptr, cast(ushort)unsigned_number);
    if (unsigned_number <= uint.max)
        return set_native(handle, key.ptr, cast(uint)unsigned_number);
    return set_native(handle, key.ptr, unsigned_number);
}

Result set_float(T)(uint handle, ref const char[16] key, T number)
    if (is(T == float) || is(T == double))
{
    ubyte[T.sizeof] encoded = nativeToLittleEndian(number);
    return set_typed_blob(handle, key, BlobType.float_, T.sizeof, encoded[]);
}

Result set_quantity(uint handle, ref const char[16] key, ref const Variant value)
{
    if (value.isDouble)
        return set_quantity_number(handle, key, value.asQuantity.unit, value.isFloat ? value.asFloat : value.asDouble);
    return value.isUlong ? set_quantity_number(handle, key, value.asQuantity.unit, value.asUlong)
                         : set_quantity_number(handle, key, value.asQuantity.unit, value.asLong);
}

Result set_quantity_number(T)(uint handle, ref const char[16] key, ScaledUnit unit, T number)
{
    enum NvsType type = nvs_type!T;
    ubyte[uint.sizeof + T.sizeof] payload = void;
    payload[0 .. uint.sizeof] = nativeToLittleEndian(unit.pack)[];
    payload[uint.sizeof .. $] = nativeToLittleEndian(number)[];
    return set_typed_blob(handle, key, BlobType.quantity, type, payload[]);
}

Result set_user(uint handle, ref const char[16] key, ref const Variant value)
{
    ref const TypeDetails details = find_type_details(value.userType);
    if (!details.pod)
        return nvs_result(NvsError.unsupported);
    if (details.name.length > ubyte.max)
        return nvs_result(NvsError.invalid_length);

    void[] payload = defaultAllocator.alloc(details.name.length + details.size);
    if (!payload.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) defaultAllocator.free(payload);

    payload[0 .. details.name.length] = cast(const(void)[])details.name;
    void[] image = payload[details.name.length .. $];
    image[] = value.user_ptr[0 .. details.size];
    return set_typed_blob(handle, key, BlobType.user, details.name.length, payload);
}

Result get_float(ubyte format, const(ubyte)[] payload, ref Variant value)
{
    if (format == float.sizeof && payload.length == float.sizeof)
    {
        ubyte[float.sizeof] encoded = void;
        encoded[] = payload[];
        value = Variant(littleEndianToNative!float(encoded));
        return Result.success;
    }
    if (format == double.sizeof && payload.length == double.sizeof)
    {
        ubyte[double.sizeof] encoded = void;
        encoded[] = payload[];
        value = Variant(littleEndianToNative!double(encoded));
        return Result.success;
    }
    return nvs_result(NvsError.corrupt);
}

Result get_quantity(ubyte format, const(ubyte)[] payload, ref Variant value)
{
    if (payload.length < uint.sizeof)
        return nvs_result(NvsError.corrupt);

    ubyte[uint.sizeof] encoded_unit = void;
    encoded_unit[] = payload[0 .. uint.sizeof];
    ScaledUnit unit;
    unit.pack = littleEndianToNative!uint(encoded_unit);

    Result result;
    switch (cast(NvsType)format)
    {
        case NvsType.i8:  result = get_quantity_number!byte(payload[4 .. $], value); break;
        case NvsType.u8:  result = get_quantity_number!ubyte(payload[4 .. $], value); break;
        case NvsType.i16: result = get_quantity_number!short(payload[4 .. $], value); break;
        case NvsType.u16: result = get_quantity_number!ushort(payload[4 .. $], value); break;
        case NvsType.i32: result = get_quantity_number!int(payload[4 .. $], value); break;
        case NvsType.u32: result = get_quantity_number!uint(payload[4 .. $], value); break;
        case NvsType.i64: result = get_quantity_number!long(payload[4 .. $], value); break;
        case NvsType.u64: result = get_quantity_number!ulong(payload[4 .. $], value); break;
        case NvsType.f32: result = get_quantity_number!float(payload[4 .. $], value); break;
        case NvsType.f64: result = get_quantity_number!double(payload[4 .. $], value); break;
        default: return nvs_result(NvsError.corrupt);
    }
    if (result)
        value.set_unit(unit);
    return result;
}

Result get_quantity_number(T)(const(ubyte)[] payload, ref Variant value)
{
    if (payload.length != T.sizeof)
        return nvs_result(NvsError.corrupt);
    ubyte[T.sizeof] encoded = void;
    encoded[] = payload[];
    value = Variant(littleEndianToNative!T(encoded));
    return Result.success;
}

Result get_user(ubyte name_length, const(ubyte)[] payload, ref Variant value)
{
    if (payload.length < name_length)
        return nvs_result(NvsError.corrupt);
    const(char)[] type_name = cast(const(char)[])payload[0 .. name_length];
    immutable(TypeDetails)* details = find_type_by_name(type_name);
    if (!details || !details.pod || !details.variant ||
        payload.length != name_length + details.size)
        return nvs_result(NvsError.incompatible_version);

    void[] record = defaultAllocator.alloc(details.size, details.alignment);
    if (!record.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) defaultAllocator.free(record);

    const(void)[] image = payload[name_length .. $];
    record[] = image[];
    return details.variant(record.ptr, value, true) ? Result.success : nvs_result(NvsError.incompatible_version);
}

Result set_typed_blob(uint handle, ref const char[16] key, BlobType type, size_t format, const(void)[] payload)
{
    if (format > ubyte.max)
        return nvs_result(NvsError.invalid_length);
    void[] bytes = defaultAllocator.alloc(blob_header_length + payload.length);
    if (!bytes.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) defaultAllocator.free(bytes);

    write_header(bytes, type, cast(ubyte)format);
    bytes[blob_header_length .. $] = payload[];
    return map_result(esp_nvs_set_blob(handle, key.ptr, bytes.ptr, bytes.length));
}

void write_header(void[] bytes, BlobType type, ubyte format)
{
    ubyte[] header = cast(ubyte[])bytes[0 .. blob_header_length];
    header[0] = 'O';
    header[1] = 'W';
    header[2] = 'V';
    header[3] = 1;
    header[4] = type;
    header[5] = format;
    header[6] = blob_guard;
    header[7] = header[4] ^ header[5] ^ header[6];
}

bool valid_header(const(void)[] bytes)
{
    if (bytes.length < blob_header_length)
        return false;
    const(ubyte)[] header = cast(const(ubyte)[])bytes[0 .. blob_header_length];
    return header[0] == 'O' && header[1] == 'W' && header[2] == 'V' && header[3] == 1 &&
           header[6] == blob_guard &&
           header[7] == (header[4] ^ header[5] ^ header[6]);
}

template nvs_type(T)
{
    static if (is(T == byte))
        enum NvsType nvs_type = NvsType.i8;
    else static if (is(T == ubyte))
        enum NvsType nvs_type = NvsType.u8;
    else static if (is(T == short))
        enum NvsType nvs_type = NvsType.i16;
    else static if (is(T == ushort))
        enum NvsType nvs_type = NvsType.u16;
    else static if (is(T == int))
        enum NvsType nvs_type = NvsType.i32;
    else static if (is(T == uint))
        enum NvsType nvs_type = NvsType.u32;
    else static if (is(T == long))
        enum NvsType nvs_type = NvsType.i64;
    else static if (is(T == ulong))
        enum NvsType nvs_type = NvsType.u64;
    else static if (is(T == float))
        enum NvsType nvs_type = NvsType.f32;
    else static if (is(T == double))
        enum NvsType nvs_type = NvsType.f64;
    else static assert(false, "unsupported NVS number type");
}

Result get_native(T)(uint handle, const(char)* key, out T value)
{
    static if (is(T == byte))
        return map_result(esp_nvs_get_i8(handle, key, &value));
    else static if (is(T == ubyte))
        return map_result(esp_nvs_get_u8(handle, key, &value));
    else static if (is(T == short))
        return map_result(esp_nvs_get_i16(handle, key, &value));
    else static if (is(T == ushort))
        return map_result(esp_nvs_get_u16(handle, key, &value));
    else static if (is(T == int))
        return map_result(esp_nvs_get_i32(handle, key, &value));
    else static if (is(T == uint))
        return map_result(esp_nvs_get_u32(handle, key, &value));
    else static if (is(T == long))
        return map_result(esp_nvs_get_i64(handle, key, &value));
    else static if (is(T == ulong))
        return map_result(esp_nvs_get_u64(handle, key, &value));
    else static assert(false, "unsupported NVS number type");
}

Result set_native(T)(uint handle, const(char)* key, T value)
{
    static if (is(T == byte))
        return map_result(esp_nvs_set_i8(handle, key, value));
    else static if (is(T == ubyte))
        return map_result(esp_nvs_set_u8(handle, key, value));
    else static if (is(T == short))
        return map_result(esp_nvs_set_i16(handle, key, value));
    else static if (is(T == ushort))
        return map_result(esp_nvs_set_u16(handle, key, value));
    else static if (is(T == int))
        return map_result(esp_nvs_set_i32(handle, key, value));
    else static if (is(T == uint))
        return map_result(esp_nvs_set_u32(handle, key, value));
    else static if (is(T == long))
        return map_result(esp_nvs_set_i64(handle, key, value));
    else static if (is(T == ulong))
        return map_result(esp_nvs_set_u64(handle, key, value));
    else static assert(false, "unsupported NVS number type");
}

enum int ESP_OK = 0;
enum int ESP_ERR_NO_MEM = 0x101;
enum int ESP_ERR_INVALID_ARG = 0x102;
enum int ESP_ERR_NOT_ALLOWED = 0x10d;
enum int ESP_ERR_NVS_BASE = 0x1100;
enum int ESP_ERR_NVS_NOT_INITIALIZED = ESP_ERR_NVS_BASE + 0x01;
enum int ESP_ERR_NVS_NOT_FOUND = ESP_ERR_NVS_BASE + 0x02;
enum int ESP_ERR_NVS_TYPE_MISMATCH = ESP_ERR_NVS_BASE + 0x03;
enum int ESP_ERR_NVS_READ_ONLY = ESP_ERR_NVS_BASE + 0x04;
enum int ESP_ERR_NVS_NOT_ENOUGH_SPACE = ESP_ERR_NVS_BASE + 0x05;
enum int ESP_ERR_NVS_INVALID_NAME = ESP_ERR_NVS_BASE + 0x06;
enum int ESP_ERR_NVS_INVALID_HANDLE = ESP_ERR_NVS_BASE + 0x07;
enum int ESP_ERR_NVS_REMOVE_FAILED = ESP_ERR_NVS_BASE + 0x08;
enum int ESP_ERR_NVS_KEY_TOO_LONG = ESP_ERR_NVS_BASE + 0x09;
enum int ESP_ERR_NVS_INVALID_STATE = ESP_ERR_NVS_BASE + 0x0b;
enum int ESP_ERR_NVS_INVALID_LENGTH = ESP_ERR_NVS_BASE + 0x0c;
enum int ESP_ERR_NVS_NO_FREE_PAGES = ESP_ERR_NVS_BASE + 0x0d;
enum int ESP_ERR_NVS_VALUE_TOO_LONG = ESP_ERR_NVS_BASE + 0x0e;
enum int ESP_ERR_NVS_PART_NOT_FOUND = ESP_ERR_NVS_BASE + 0x0f;
enum int ESP_ERR_NVS_NEW_VERSION_FOUND = ESP_ERR_NVS_BASE + 0x10;
enum int ESP_ERR_NVS_CORRUPT_KEY_PART = ESP_ERR_NVS_BASE + 0x17;

void terminate(const(char)[] source, ref char[16] destination)
{
    destination[0 .. source.length] = source[];
    destination[source.length] = 0;
}

Result nvs_result(NvsError error)
{
    return Result(cast(uint)error);
}

Result map_result(int result)
{
    NvsError error;
    switch (result)
    {
        case ESP_OK:                         error = NvsError.none; break;
        case ESP_ERR_NO_MEM:                 error = NvsError.no_memory; break;
        case ESP_ERR_INVALID_ARG:            error = NvsError.invalid_parameter; break;
        case ESP_ERR_NOT_ALLOWED:
        case ESP_ERR_NVS_READ_ONLY:          error = NvsError.read_only; break;
        case ESP_ERR_NVS_NOT_INITIALIZED:    error = NvsError.not_initialized; break;
        case ESP_ERR_NVS_NOT_FOUND:          error = NvsError.not_found; break;
        case ESP_ERR_NVS_TYPE_MISMATCH:      error = NvsError.type_mismatch; break;
        case ESP_ERR_NVS_NOT_ENOUGH_SPACE:
        case ESP_ERR_NVS_NO_FREE_PAGES:      error = NvsError.not_enough_space; break;
        case ESP_ERR_NVS_INVALID_NAME:
        case ESP_ERR_NVS_KEY_TOO_LONG:       error = NvsError.invalid_name; break;
        case ESP_ERR_NVS_INVALID_HANDLE:     error = NvsError.invalid_handle; break;
        case ESP_ERR_NVS_REMOVE_FAILED:      error = NvsError.write_failed; break;
        case ESP_ERR_NVS_INVALID_LENGTH:     error = NvsError.invalid_length; break;
        case ESP_ERR_NVS_VALUE_TOO_LONG:     error = NvsError.value_too_long; break;
        case ESP_ERR_NVS_PART_NOT_FOUND:     error = NvsError.partition_not_found; break;
        case ESP_ERR_NVS_NEW_VERSION_FOUND:  error = NvsError.incompatible_version; break;
        case ESP_ERR_NVS_INVALID_STATE:
        case ESP_ERR_NVS_CORRUPT_KEY_PART:   error = NvsError.corrupt; break;
        default:                             error = NvsError.failed; break;
    }
    return nvs_result(error);
}

extern(C) nothrow @nogc
{
    pragma(mangle, "nvs_open") int esp_nvs_open(const(char)* namespace_name, int mode, uint* handle);
    pragma(mangle, "nvs_close") void esp_nvs_close(uint handle);
    pragma(mangle, "nvs_commit") int esp_nvs_commit(uint handle);
    pragma(mangle, "nvs_find_key") int esp_nvs_find_key(uint handle, const(char)* key, int* type);
    pragma(mangle, "nvs_get_i8") int esp_nvs_get_i8(uint handle, const(char)* key, byte* value);
    pragma(mangle, "nvs_get_u8") int esp_nvs_get_u8(uint handle, const(char)* key, ubyte* value);
    pragma(mangle, "nvs_get_i16") int esp_nvs_get_i16(uint handle, const(char)* key, short* value);
    pragma(mangle, "nvs_get_u16") int esp_nvs_get_u16(uint handle, const(char)* key, ushort* value);
    pragma(mangle, "nvs_get_i32") int esp_nvs_get_i32(uint handle, const(char)* key, int* value);
    pragma(mangle, "nvs_get_u32") int esp_nvs_get_u32(uint handle, const(char)* key, uint* value);
    pragma(mangle, "nvs_get_i64") int esp_nvs_get_i64(uint handle, const(char)* key, long* value);
    pragma(mangle, "nvs_get_u64") int esp_nvs_get_u64(uint handle, const(char)* key, ulong* value);
    pragma(mangle, "nvs_get_str") int esp_nvs_get_str(uint handle, const(char)* key, char* value, size_t* length);
    pragma(mangle, "nvs_get_blob") int esp_nvs_get_blob(uint handle, const(char)* key, void* value, size_t* length);
    pragma(mangle, "nvs_set_i8") int esp_nvs_set_i8(uint handle, const(char)* key, byte value);
    pragma(mangle, "nvs_set_u8") int esp_nvs_set_u8(uint handle, const(char)* key, ubyte value);
    pragma(mangle, "nvs_set_i16") int esp_nvs_set_i16(uint handle, const(char)* key, short value);
    pragma(mangle, "nvs_set_u16") int esp_nvs_set_u16(uint handle, const(char)* key, ushort value);
    pragma(mangle, "nvs_set_i32") int esp_nvs_set_i32(uint handle, const(char)* key, int value);
    pragma(mangle, "nvs_set_u32") int esp_nvs_set_u32(uint handle, const(char)* key, uint value);
    pragma(mangle, "nvs_set_i64") int esp_nvs_set_i64(uint handle, const(char)* key, long value);
    pragma(mangle, "nvs_set_u64") int esp_nvs_set_u64(uint handle, const(char)* key, ulong value);
    pragma(mangle, "nvs_set_blob") int esp_nvs_set_blob(uint handle, const(char)* key, const(void)* value, size_t length);
    pragma(mangle, "nvs_erase_key") int esp_nvs_erase_key(uint handle, const(char)* key);
}
