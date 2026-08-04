module urt.driver.esp32.nvs;

import urt.driver.nvs : Nvs, NvsError, NvsOpenMode;
import urt.mem.alloc : alloc, free, MemFlags;
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

Result nvs_hw_get(ref Nvs nvs, const(char)[] key, out Variant value)
{
    char[16] name = void;
    terminate(key, name);

    int raw_type;
    Result result = map_result(esp_nvs_find_key(nvs.driver_handle, name.ptr, &raw_type));
    if (!result)
        return result;

    NvsType type = cast(NvsType)raw_type;
    if (is_integer_type(type))
        return get_integer(nvs.driver_handle, name, type, value);

    switch (type)
    {
        case NvsType.string_:
        case NvsType.blob:
            return get_buffer(nvs.driver_handle, name, type, value);
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
        return set_string(nvs.driver_handle, name, value.asString);
    if (value.isBuffer)
        return map_result(esp_nvs_set_blob(nvs.driver_handle, name.ptr, value.asBuffer.ptr, value.asBuffer.length));
    if (!value.isNumber)
        return value.isUserType ? set_user(nvs.driver_handle, name, value) : nvs_result(NvsError.unsupported);
    if (value.is_enum)
        return nvs_result(NvsError.unsupported);
    if (value.isQuantity)
        return set_quantity(nvs.driver_handle, name, value);
    if (value.isDouble)
        return set_float(nvs.driver_handle, name, value);
    return set_integer(nvs.driver_handle, name, value);
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
    boolean = 0,
    float_ = 1,
    quantity = 3,
    user = 4,
    null_ = 5,
}

enum ubyte blob_guard = 0xa5;
enum size_t blob_header_length = 8;

struct EncodedNumber
{
    ulong bits;
    NvsType type;
}

Result get_integer(uint handle, ref const char[16] key, NvsType type, out Variant value)
{
    ulong bits;
    int result;
    switch (type)
    {
        case NvsType.i8:  result = esp_nvs_get_i8(handle, key.ptr, cast(byte*)&bits); break;
        case NvsType.u8:  result = esp_nvs_get_u8(handle, key.ptr, cast(ubyte*)&bits); break;
        case NvsType.i16: result = esp_nvs_get_i16(handle, key.ptr, cast(short*)&bits); break;
        case NvsType.u16: result = esp_nvs_get_u16(handle, key.ptr, cast(ushort*)&bits); break;
        case NvsType.i32: result = esp_nvs_get_i32(handle, key.ptr, cast(int*)&bits); break;
        case NvsType.u32: result = esp_nvs_get_u32(handle, key.ptr, cast(uint*)&bits); break;
        case NvsType.i64: result = esp_nvs_get_i64(handle, key.ptr, cast(long*)&bits); break;
        case NvsType.u64: result = esp_nvs_get_u64(handle, key.ptr, &bits); break;
        default: return nvs_result(NvsError.type_mismatch);
    }
    if (result != ESP_OK)
        return map_result(result);

    return decode_number(type, bits, value);
}

Result get_buffer(uint handle, ref const char[16] key, NvsType type, out Variant value)
{
    size_t length;
    Result result = map_result(get_buffer_native(handle, key.ptr, type, null, &length));
    if (!result)
        return result;
    if (length == 0)
    {
        if (type == NvsType.string_)
            return nvs_result(NvsError.corrupt);
        return Result.success;
    }

    void[] bytes = alloc(length, MemFlags.fastest);
    if (!bytes.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) free(bytes);

    result = map_result(get_buffer_native(handle, key.ptr, type, bytes.ptr, &length));
    if (!result)
        return result;
    if (length == 0 || length > bytes.length)
        return nvs_result(NvsError.corrupt);
    const(void)[] record = bytes[0 .. length];
    if (type == NvsType.string_)
    {
        if ((cast(const(char)[])record)[$-1] != 0)
            return nvs_result(NvsError.corrupt);
        value = Variant(cast(const(char)[])record[0 .. $-1]);
        return Result.success;
    }
    return get_blob(record, value);
}

int get_buffer_native(uint handle, const(char)* key, NvsType type, void* value, size_t* length)
{
    return type == NvsType.string_ ? esp_nvs_get_str(handle, key, cast(char*)value, length)
                                   : esp_nvs_get_blob(handle, key, value, length);
}

Result get_blob(const(void)[] bytes, out Variant value)
{
    if (!valid_header(bytes))
    {
        value = Variant(bytes);
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
        case BlobType.quantity:
            return get_quantity(format, payload, value);
        case BlobType.user:
            return get_user(format, payload, value);
        default:
            return nvs_result(NvsError.incompatible_version);
    }
}

Result set_string(uint handle, ref const char[16] key, const(char)[] value)
{
    char[] terminated = cast(char[])alloc(value.length + 1, MemFlags.fastest);
    if (!terminated.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) free(terminated);

    foreach (size_t i, char character; value)
    {
        if (!character)
            return nvs_result(NvsError.invalid_parameter);
        terminated[i] = character;
    }
    terminated[$-1] = 0;
    return map_result(esp_nvs_set_str(handle, key.ptr, terminated.ptr));
}

Result set_integer(uint handle, ref const char[16] key, ref const Variant value)
{
    EncodedNumber number = encode_number(value);
    int result;
    switch (number.type)
    {
        case NvsType.i8:  result = esp_nvs_set_i8(handle, key.ptr, cast(byte)number.bits); break;
        case NvsType.u8:  result = esp_nvs_set_u8(handle, key.ptr, cast(ubyte)number.bits); break;
        case NvsType.i16: result = esp_nvs_set_i16(handle, key.ptr, cast(short)number.bits); break;
        case NvsType.u16: result = esp_nvs_set_u16(handle, key.ptr, cast(ushort)number.bits); break;
        case NvsType.i32: result = esp_nvs_set_i32(handle, key.ptr, cast(int)number.bits); break;
        case NvsType.u32: result = esp_nvs_set_u32(handle, key.ptr, cast(uint)number.bits); break;
        case NvsType.i64: result = esp_nvs_set_i64(handle, key.ptr, cast(long)number.bits); break;
        case NvsType.u64: result = esp_nvs_set_u64(handle, key.ptr, number.bits); break;
        default: return nvs_result(NvsError.type_mismatch);
    }
    return map_result(result);
}

Result set_float(uint handle, ref const char[16] key, ref const Variant value)
{
    EncodedNumber number = encode_number(value);
    ubyte[ulong.sizeof] encoded = void;
    size_t size = number_size(number.type);
    write_little_endian(number.bits, encoded[0 .. size]);
    return set_typed_blob(handle, key, BlobType.float_, size, encoded[0 .. size]);
}

Result set_quantity(uint handle, ref const char[16] key, ref const Variant value)
{
    EncodedNumber number = encode_number(value);
    size_t size = number_size(number.type);
    ubyte[uint.sizeof + ulong.sizeof] payload = void;
    write_little_endian(value.asQuantity.unit.pack, payload[0 .. uint.sizeof]);
    write_little_endian(number.bits, payload[uint.sizeof .. uint.sizeof + size]);
    return set_typed_blob(handle, key, BlobType.quantity, number.type,
                          payload[0 .. uint.sizeof + size]);
}

Result set_user(uint handle, ref const char[16] key, ref const Variant value)
{
    ref const TypeDetails details = find_type_details(value.userType);
    if (!details.pod)
        return nvs_result(NvsError.unsupported);
    if (details.name.length > ubyte.max)
        return nvs_result(NvsError.invalid_length);

    void[] payload = alloc(details.name.length + details.size, MemFlags.fastest);
    if (!payload.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) free(payload);

    payload[0 .. details.name.length] = cast(const(void)[])details.name;
    void[] image = payload[details.name.length .. $];
    image[] = value.user_ptr[0 .. details.size];
    return set_typed_blob(handle, key, BlobType.user, details.name.length, payload);
}

Result get_float(ubyte format, const(ubyte)[] payload, out Variant value)
{
    NvsType type = format == float.sizeof ? NvsType.f32 : NvsType.f64;
    if (format != float.sizeof && format != double.sizeof)
        return nvs_result(NvsError.corrupt);
    return get_number(type, payload, value);
}

Result get_quantity(ubyte format, const(ubyte)[] payload, out Variant value)
{
    if (payload.length < uint.sizeof)
        return nvs_result(NvsError.corrupt);

    ScaledUnit unit;
    unit.pack = cast(uint)read_little_endian(payload[0 .. uint.sizeof]);

    Result result = get_number(cast(NvsType)format, payload[uint.sizeof .. $], value);
    if (result)
        value.set_unit(unit);
    return result;
}

Result get_number(NvsType type, const(ubyte)[] payload, out Variant value)
{
    size_t size = number_size(type);
    if (!valid_number_type(type) || payload.length != size)
        return nvs_result(NvsError.corrupt);

    return decode_number(type, read_little_endian(payload), value);
}

Result decode_number(NvsType type, ulong bits, out Variant value)
{
    size_t size = number_size(type);
    ubyte kind = cast(ubyte)type & 0xf0;
    if (kind == 0x00)
        value = Variant(bits);
    else if (kind == 0x10)
    {
        uint shift = cast(uint)((ulong.sizeof - size) * 8);
        value = Variant(cast(long)(bits << shift) >> shift);
    }
    else if (type == NvsType.f32)
    {
        uint float_bits = cast(uint)bits;
        value = Variant(*cast(float*)&float_bits);
    }
    else
        value = Variant(*cast(double*)&bits);
    return Result.success;
}

Result get_user(ubyte name_length, const(ubyte)[] payload, out Variant value)
{
    if (payload.length < name_length)
        return nvs_result(NvsError.corrupt);
    const(char)[] type_name = cast(const(char)[])payload[0 .. name_length];
    immutable(TypeDetails)* details = find_type_by_name(type_name);
    if (!details || !details.pod || !details.variant ||
        payload.length != name_length + details.size)
        return nvs_result(NvsError.incompatible_version);

    void[] record = alloc(details.size, details.alignment, MemFlags.fastest);
    if (!record.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) free(record);

    const(void)[] image = payload[name_length .. $];
    record[] = image[];
    return details.variant(record.ptr, value, true) ? Result.success : nvs_result(NvsError.incompatible_version);
}

Result set_typed_blob(uint handle, ref const char[16] key, BlobType type, size_t format, const(void)[] payload)
{
    if (format > ubyte.max)
        return nvs_result(NvsError.invalid_length);
    void[] bytes = alloc(blob_header_length + payload.length, MemFlags.fastest);
    if (!bytes.ptr)
        return nvs_result(NvsError.no_memory);
    scope(exit) free(bytes);

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

EncodedNumber encode_number(ref const Variant value)
{
    EncodedNumber result;
    if (value.isDouble)
    {
        if (value.isFloat)
        {
            float number = value.asFloat;
            result.bits = *cast(uint*)&number;
            result.type = NvsType.f32;
        }
        else
        {
            double number = value.asDouble;
            result.bits = *cast(ulong*)&number;
            result.type = NvsType.f64;
        }
        return result;
    }

    if (value.isUlong)
        result.bits = value.asUlong;
    else
    {
        long number = value.asLong;
        result.bits = cast(ulong)number;
        if (number < 0)
        {
            result.type = number >= byte.min ? NvsType.i8 :
                          number >= short.min ? NvsType.i16 :
                          number >= int.min ? NvsType.i32 : NvsType.i64;
            return result;
        }
    }

    result.type = result.bits <= ubyte.max ? NvsType.u8 :
                  result.bits <= ushort.max ? NvsType.u16 :
                  result.bits <= uint.max ? NvsType.u32 : NvsType.u64;
    return result;
}

size_t number_size(NvsType type)
{
    return cast(ubyte)type & 0x0f;
}

bool is_integer_type(NvsType type)
{
    ubyte code = cast(ubyte)type;
    ubyte size = code & 0x0f;
    ubyte kind = code & 0xf0;
    return (kind == 0x00 || kind == 0x10) &&
           (size == 1 || size == 2 || size == 4 || size == 8);
}

bool valid_number_type(NvsType type)
{
    return is_integer_type(type) || type == NvsType.f32 || type == NvsType.f64;
}

ulong read_little_endian(const(ubyte)[] value)
{
    ulong result;
    foreach_reverse (ubyte byte_; value)
        result = (result << 8) | byte_;
    return result;
}

void write_little_endian(ulong bits, ubyte[] value)
{
    foreach (ref ubyte byte_; value)
    {
        byte_ = cast(ubyte)bits;
        bits >>= 8;
    }
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
    pragma(mangle, "nvs_set_str") int esp_nvs_set_str(uint handle, const(char)* key, const(char)* value);
    pragma(mangle, "nvs_set_blob") int esp_nvs_set_blob(uint handle, const(char)* key, const(void)* value, size_t length);
    pragma(mangle, "nvs_erase_key") int esp_nvs_erase_key(uint handle, const(char)* key);
}
