module urt.digest.sha;

import urt.endian;

version (Espressif)
{
    version (ESP32) {} else
        version = Espressif_Modern;
}

nothrow @nogc: // pure


struct SHA1Context
{
    enum DigestBits = 160;
    enum DigestLen = DigestBits / 8;

    version (Espressif)
        private SHA_CTX ctx;
    else
    {
        enum DigestElements = DigestBits / 32;

        ubyte[64] data;
        ulong bitlen;
        uint datalen;
        uint[DigestElements] state;

        alias transform = sha1_transform;

        enum uint[DigestElements] initState = [ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 ];

        __gshared immutable uint[4] K = [ 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6 ];
    }
}

struct SHA224Context
{
    enum DigestBits = 224;
    enum DigestLen = DigestBits / 8;

    // TODO: ESP32 hardware SHA-224 should be possible by writing the SHA-224 IV to SHA_TEXT_BASE,
    // triggering SHA_256_LOAD_REG, then running as SHA2_256 with truncated output.
    version (Espressif_Modern)
        private SHA_CTX ctx;
    else
    {
        enum DigestElements = DigestBits / 32;
        enum StateElements = 256 / 32;

        ubyte[64] data;
        ulong bitlen;
        uint datalen;
        uint[StateElements] state;

        alias transform = sha256_transform;

        enum uint[StateElements] initState = [ 0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939,
                                               0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4 ];
    }
}

struct SHA256Context
{
    enum DigestBits = 256;
    enum DigestLen = DigestBits / 8;

    version (Espressif)
        private SHA_CTX ctx;
    else
    {
        enum DigestElements = DigestBits / 32;
        enum StateElements = DigestBits / 32;

        ubyte[64] data;
        ulong bitlen;
        uint datalen;
        uint[StateElements] state;

        alias transform = sha256_transform;

        enum uint[StateElements] initState = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];
    }
    version (Espressif_Modern) {} else {
        __gshared immutable uint[64] K = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ];
    }
}

void sha_init(Context)(ref Context ctx)
{
    static if (esp_hardware!Context)
    {
        version (ESP32)
        {
            ets_sha_enable();
            ets_sha_init(&ctx.ctx);
        }
        else
        {
            ets_sha_enable();
            static if (is(Context == SHA1Context))
                ets_sha_init(&ctx.ctx, SHA_TYPE.SHA1);
            else static if (is(Context == SHA224Context))
                ets_sha_init(&ctx.ctx, SHA_TYPE.SHA2_224);
            else
                ets_sha_init(&ctx.ctx, SHA_TYPE.SHA2_256);
            ets_sha_starts(&ctx.ctx, 0);
        }
    }
    else
    {
        ctx.datalen = 0;
        ctx.bitlen = 0;
        ctx.state = Context.initState;
    }
}

void sha_update(Context)(ref Context ctx, const void[] input)
{
    static if (esp_hardware!Context)
    {
        version (ESP32)
        {
            static if (is(Context == SHA1Context))
                enum sha_type = SHA_TYPE.SHA1;
            else
                enum sha_type = SHA_TYPE.SHA2_256;
            ets_sha_update(&ctx.ctx, sha_type, cast(const ubyte*)input.ptr, input.length * 8);
        }
        else
            ets_sha_update(&ctx.ctx, cast(const ubyte*)input.ptr, cast(uint)input.length, true);
    }
    else
    {
        const(ubyte)[] data = cast(ubyte[])input;

        while (data.length > 0)
        {
            if (ctx.datalen + data.length < 64)
            {
                ctx.data[ctx.datalen .. ctx.datalen + data.length] = data[];
                ctx.datalen += cast(uint)data.length;
                break;
            }

            ctx.data[ctx.datalen .. 64] = data[0 .. 64 - ctx.datalen];
            data = data[64 - ctx.datalen .. $];
            ctx.bitlen += 512;
            ctx.datalen = 0;
            Context.transform(ctx, ctx.data);
        }
    }
}

ubyte[Context.DigestLen] sha_finalise(Context)(ref Context ctx)
{
    static if (esp_hardware!Context)
    {
        version (ESP32)
        {
            static if (is(Context == SHA1Context))
                enum sha_type = SHA_TYPE.SHA1;
            else
                enum sha_type = SHA_TYPE.SHA2_256;
            ubyte[Context.DigestLen] digest;
            ets_sha_finish(&ctx.ctx, sha_type, digest.ptr);
            ets_sha_disable();
            return digest;
        }
        else
        {
            ubyte[Context.DigestLen] digest;
            ets_sha_finish(&ctx.ctx, digest.ptr);
            ets_sha_disable();
            return digest;
        }
    }
    else
    {
        uint i = ctx.datalen;

        ctx.data[i++] = 0x80;
        if (ctx.datalen >= 56)
        {
            ctx.data[i .. 64] = 0x00;
            Context.transform(ctx, ctx.data);
            i = 0;
        }
        ctx.data[i .. 56] = 0x00;

        ctx.bitlen += ctx.datalen * 8;
        ctx.data[56..64] = ctx.bitlen.nativeToBigEndian;
        Context.transform(ctx, ctx.data);

        uint[Context.DigestElements] digest = void;
        foreach (uint j; 0 .. Context.DigestElements)
            digest[j] = byte_reverse(ctx.state[j]);

        return cast(ubyte[Context.DigestLen])digest;
    }
}

unittest
{
    import urt.encoding;

    // SHA-1
    SHA1Context ctx;

    // empty
    sha_init(ctx);
    auto digest = sha_finalise(ctx);
    assert(digest == HexDecode!"da39a3ee5e6b4b0d3255bfef95601890afd80709");

    // single string
    sha_init(ctx);
    sha_update(ctx, "Hello, World!");
    digest = sha_finalise(ctx);
    assert(digest == HexDecode!"0a0a9f2a6772942557ab5355d76af442f8f65e01");

    // FIPS 180 test vectors
    sha_init(ctx);
    sha_update(ctx, "abc");
    digest = sha_finalise(ctx);
    assert(digest == HexDecode!"a9993e364706816aba3e25717850c26c9cd0d89d");

    // progressive
    sha_init(ctx);
    sha_update(ctx, "Hello, ");
    sha_update(ctx, "World!");
    digest = sha_finalise(ctx);
    assert(digest == HexDecode!"0a0a9f2a6772942557ab5355d76af442f8f65e01");

    // multi-block (>64 bytes)
    sha_init(ctx);
    sha_update(ctx, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    digest = sha_finalise(ctx);
    assert(digest == HexDecode!"84983e441c3bd26ebaae4aa1f95129e5e54670f1");

    // SHA-224
    SHA224Context ctx3;

    // empty
    sha_init(ctx3);
    auto digest3 = sha_finalise(ctx3);
    assert(digest3 == HexDecode!"d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f");

    // FIPS 180 test vector
    sha_init(ctx3);
    sha_update(ctx3, "abc");
    digest3 = sha_finalise(ctx3);
    assert(digest3 == HexDecode!"23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7");

    // progressive
    sha_init(ctx3);
    sha_update(ctx3, "Hello, ");
    sha_update(ctx3, "World!");
    auto digest3b = sha_finalise(ctx3);
    sha_init(ctx3);
    sha_update(ctx3, "Hello, World!");
    digest3 = sha_finalise(ctx3);
    assert(digest3 == digest3b);

    // multi-block
    sha_init(ctx3);
    sha_update(ctx3, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    digest3 = sha_finalise(ctx3);
    assert(digest3 == HexDecode!"75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525");

    // SHA-256
    SHA256Context ctx2;

    // empty
    sha_init(ctx2);
    auto digest2 = sha_finalise(ctx2);
    assert(digest2 == HexDecode!"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    // single string
    sha_init(ctx2);
    sha_update(ctx2, "Hello, World!");
    digest2 = sha_finalise(ctx2);
    assert(digest2 == HexDecode!"dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f");

    // FIPS 180 test vectors
    sha_init(ctx2);
    sha_update(ctx2, "abc");
    digest2 = sha_finalise(ctx2);
    assert(digest2 == HexDecode!"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    // progressive
    sha_init(ctx2);
    sha_update(ctx2, "Hello, ");
    sha_update(ctx2, "World!");
    digest2 = sha_finalise(ctx2);
    assert(digest2 == HexDecode!"dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f");

    // multi-block
    sha_init(ctx2);
    sha_update(ctx2, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    digest2 = sha_finalise(ctx2);
    assert(digest2 == HexDecode!"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}


private:

template esp_hardware(Context)
{
    version (Espressif_Modern)
        enum esp_hardware = true;
    else version (Espressif)
        // SHA-224 hardware on ESP32 Classic would need SHA-256 with custom IV
        // (see TODO on SHA224Context); fall through to software for now.
        enum esp_hardware = !is(Context == SHA224Context);
    else
        enum esp_hardware = false;
}

version (Espressif) {} else
void sha1_transform(Context)(ref Context ctx, const ubyte[] data)
{
    static uint ROTLEFT(uint a, uint b) => (a << b) | (a >> (32 - b));

    uint a, b, c, d, e, i, j, t;
    uint[80] m = void;

    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) + (data[j + 1] << 16) + (data[j + 2] << 8) + (data[j + 3]);
    for (; i < 80; ++i)
    {
        m[i] = (m[i - 3] ^ m[i - 8] ^ m[i - 14] ^ m[i - 16]);
        m[i] = (m[i] << 1) | (m[i] >> 31);
    }

    a = ctx.state[0];
    b = ctx.state[1];
    c = ctx.state[2];
    d = ctx.state[3];
    e = ctx.state[4];

    for (i = 0; i < 20; ++i)
    {
        t = ROTLEFT(a, 5) + ((b & c) ^ (~b & d)) + e + SHA1Context.K[0] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 40; ++i)
    {
        t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + SHA1Context.K[1] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 60; ++i)
    {
        t = ROTLEFT(a, 5) + ((b & c) ^ (b & d) ^ (c & d))  + e + SHA1Context.K[2] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 80; ++i)
    {
        t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + SHA1Context.K[3] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }

    ctx.state[0] += a;
    ctx.state[1] += b;
    ctx.state[2] += c;
    ctx.state[3] += d;
    ctx.state[4] += e;
}

version (Espressif_Modern) {} else
void sha256_transform(Context)(ref Context ctx, const ubyte[] data)
{
    static uint ROTRIGHT(uint a, uint b) => (a >> b) | (a << (32 - b));

    static uint CH(uint x, uint y, uint z) => (x & y) ^ (~x & z);
    static uint MAJ(uint x, uint y, uint z) => (x & y) ^ (x & z) ^ (y & z);
    static uint EP0(uint x) => ROTRIGHT(x, 2) ^ ROTRIGHT(x, 13) ^ ROTRIGHT(x, 22);
    static uint EP1(uint x) => ROTRIGHT(x, 6) ^ ROTRIGHT(x, 11) ^ ROTRIGHT(x, 25);
    static uint SIG0(uint x) => ROTRIGHT(x, 7) ^ ROTRIGHT(x, 18) ^ ((x) >> 3);
    static uint SIG1(uint x) => ROTRIGHT(x, 17) ^ ROTRIGHT(x, 19) ^ ((x) >> 10);

    uint a, b, c, d, e, f, g, h, i, j, t1, t2;
    uint[64] m = void;

    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | (data[j + 3]);
    for (; i < 64; ++i)
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];

    a = ctx.state[0];
    b = ctx.state[1];
    c = ctx.state[2];
    d = ctx.state[3];
    e = ctx.state[4];
    f = ctx.state[5];
    g = ctx.state[6];
    h = ctx.state[7];

    for (i = 0; i < 64; ++i)
    {
        t1 = h + EP1(e) + CH(e,f,g) + SHA256Context.K[i] + m[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    ctx.state[0] += a;
    ctx.state[1] += b;
    ctx.state[2] += c;
    ctx.state[3] += d;
    ctx.state[4] += e;
    ctx.state[5] += f;
    ctx.state[6] += g;
    ctx.state[7] += h;
}


// ESP32 (original) has a different ROM API from all later chips:
//   - ets_sha_init takes no type; type passed to update/finish instead
//   - ets_sha_update size is in bits, not bytes; no ets_sha_starts
//   - smaller SHA_CTX struct
//   - no SHA224 in ROM (only SHA1=0, SHA2_256=1)
version (Espressif):

private extern(C) nothrow @nogc
{
    void ets_sha_enable();
    void ets_sha_disable();

    version (Espressif_Modern)
    {
        int ets_sha_init(SHA_CTX* ctx, SHA_TYPE type);
        int ets_sha_starts(SHA_CTX* ctx, ushort sha512_t);
        void ets_sha_update(SHA_CTX* ctx, const ubyte* input, uint input_bytes, bool update_ctx);
        int ets_sha_finish(SHA_CTX* ctx, ubyte* output);
    }
    else
    {
        void ets_sha_init(SHA_CTX* ctx);
        void ets_sha_update(SHA_CTX* ctx, SHA_TYPE type, const ubyte* input, size_t input_bits);
        void ets_sha_finish(SHA_CTX* ctx, SHA_TYPE type, ubyte* output);
    }
}

version (Espressif_Modern)
{
    private enum SHA_TYPE : int { SHA1 = 0, SHA2_224, SHA2_256 }

    private struct SHA_CTX
    {
        bool start;
        bool in_hardware;
        SHA_TYPE type;
        uint[16] state;
        ubyte[128] buffer;
        uint[4] total_bits;
    }
}
else
{
    private enum SHA_TYPE : int { SHA1 = 0, SHA2_256 }

    private struct SHA_CTX
    {
        bool start;
        uint[4] total_input_bits;
    }
}
