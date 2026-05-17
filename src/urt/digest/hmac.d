module urt.digest.hmac;

import urt.digest.sha;

nothrow @nogc:


// Templated HMAC over any digest Context that exposes DigestLen + BlockBytes
// and works with sha_init/sha_update/sha_finalise.
struct HMACContext(Context)
{
    Context inner;
    ubyte[Context.BlockBytes] outer_pad;
}


void hmac_init(Context)(ref HMACContext!Context hctx, const(ubyte)[] key)
{
    enum block = Context.BlockBytes;

    ubyte[block] key_block = 0;
    if (key.length > block)
    {
        // RFC 2104: keys longer than block size are hashed first
        Context tmp;
        sha_init(tmp);
        sha_update(tmp, key);
        auto digest = sha_finalise(tmp);
        key_block[0 .. Context.DigestLen] = digest[];
    }
    else
        key_block[0 .. key.length] = key[];

    ubyte[block] inner_pad = void;
    foreach (i; 0 .. block)
    {
        inner_pad[i] = key_block[i] ^ 0x36;
        hctx.outer_pad[i] = key_block[i] ^ 0x5c;
    }

    sha_init(hctx.inner);
    sha_update(hctx.inner, inner_pad[]);
}

void hmac_update(Context)(ref HMACContext!Context hctx, const(void)[] data)
{
    sha_update(hctx.inner, data);
}

ubyte[Context.DigestLen] hmac_finalise(Context)(ref HMACContext!Context hctx)
{
    auto inner_digest = sha_finalise(hctx.inner);

    Context outer;
    sha_init(outer);
    sha_update(outer, hctx.outer_pad[]);
    sha_update(outer, inner_digest[]);
    return sha_finalise(outer);
}


// One-shot convenience.
ubyte[Context.DigestLen] hmac(Context)(const(ubyte)[] key, const(void)[] msg)
{
    HMACContext!Context h;
    hmac_init(h, key);
    hmac_update(h, msg);
    return hmac_finalise(h);
}


unittest
{
    // RFC 4231 test vectors for HMAC-SHA-256

    // TC1: 20-byte key (shorter than block)
    static immutable ubyte[32] tc1_expected = [
        0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce,
        0xaf, 0x0b, 0xf1, 0x2b, 0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7,
        0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7,
    ];
    ubyte[20] tc1_key = 0x0b;
    auto tc1 = hmac!SHA256Context(tc1_key[], "Hi There");
    assert(tc1 == tc1_expected);

    // TC2: 4-byte ASCII key
    static immutable ubyte[32] tc2_expected = [
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26,
        0x08, 0x95, 0x75, 0xc7, 0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    ];
    auto tc2 = hmac!SHA256Context(cast(const(ubyte)[])"Jefe", "what do ya want for nothing?");
    assert(tc2 == tc2_expected);

    // TC6: 131-byte key (exercises hash-the-key branch)
    static immutable ubyte[32] tc6_expected = [
        0x60, 0xe4, 0x31, 0x59, 0x1e, 0xe0, 0xb6, 0x7f, 0x0d, 0x8a, 0x26, 0xaa,
        0xcb, 0xf5, 0xb7, 0x7f, 0x8e, 0x0b, 0xc6, 0x21, 0x37, 0x28, 0xc5, 0x14,
        0x05, 0x46, 0x04, 0x0f, 0x0e, 0xe3, 0x7f, 0x54,
    ];
    ubyte[131] tc6_key = 0xaa;
    auto tc6 = hmac!SHA256Context(tc6_key[], "Test Using Larger Than Block-Size Key - Hash Key First");
    assert(tc6 == tc6_expected);
}
