module urt.crypto.pki;

import urt.array;
import urt.crypto.der;
import urt.crypto.pem;
import urt.digest.sha : SHA256Context, sha_init, sha_update, sha_finalise;
import urt.mem;
import urt.result;
import urt.string;
import urt.time;

nothrow @nogc:


struct KeyPair
{
nothrow @nogc:
    version (Windows)
    {
        BCRYPT_ALG_HANDLE halg;
        BCRYPT_KEY_HANDLE hcng;
    }

    bool valid() const pure
    {
        version (Windows)
            return hcng !is null;
        else
            return false;
    }
}

struct CertRef
{
nothrow @nogc:
    version (Windows)
    {
        PCCERT_CONTEXT context;
        HCERTSTORE store;
        NCRYPT_KEY_HANDLE hncrypt;  // persisted NCrypt key for SChannel (set by associate_key)
    }

    bool valid() const pure
    {
        version (Windows)
            return context !is null;
        else
            return false;
    }
}


Result generate_keypair(out KeyPair kp)
{
    version (Windows)
    {
        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);

        status = BCryptGenerateKeyPair(kp.halg, &kp.hcng, 256, 0);
        if (status != 0)
        {
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return Result(cast(uint)status);
        }

        status = BCryptFinalizeKeyPair(kp.hcng, 0);
        if (status != 0)
        {
            BCryptDestroyKey(kp.hcng);
            kp.hcng = null;
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return Result(cast(uint)status);
        }

        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

void free_keypair(ref KeyPair kp)
{
    version (Windows)
    {
        if (kp.hcng !is null)
            BCryptDestroyKey(kp.hcng);
        if (kp.halg !is null)
            BCryptCloseAlgorithmProvider(kp.halg, 0);
        kp.hcng = null;
        kp.halg = null;
    }
}

Result create_self_signed(ref KeyPair key, out CertRef cert, const(char)[] cn, const(char)[] hostname = null, uint validity_days = 365)
{
    version (Windows)
        return create_self_signed_win32(key, cert, cn, hostname, validity_days);
    else
        return create_self_signed_portable(key, cert, cn, hostname, validity_days);
}

private Result create_self_signed_win32(ref KeyPair key, out CertRef cert, const(char)[] cn, const(char)[] hostname, uint validity_days = 365)
{
    version (Windows)
    {
        // create a persisted NCrypt ECDSA P-256 key (SChannel requires persisted keys)
        NCRYPT_PROV_HANDLE hprov;
        SECURITY_STATUS ss = NCryptOpenStorageProvider(&hprov, MS_KEY_STORAGE_PROVIDER.ptr, 0);
        if (ss != 0)
            return Result(cast(uint)ss);

        wchar[48] name_buf = void;
        cast(void)generate_key_name(name_buf[]);

        NCRYPT_KEY_HANDLE hncrypt;
        ss = NCryptCreatePersistedKey(hprov, &hncrypt, BCRYPT_ECDSA_P256_ALGORITHM.ptr, name_buf.ptr, 0, NCRYPT_OVERWRITE_KEY_FLAG);
        NCryptFreeObject(hprov);
        if (ss != 0)
            return Result(cast(uint)ss);

        ss = NCryptFinalizeKey(hncrypt, 0);
        if (ss != 0)
        {
            NCryptFreeObject(hncrypt);
            return Result(cast(uint)ss);
        }

        // encode subject name as DER
        ubyte[128] name_der = void;
        ptrdiff_t der_len = der_name_cn(name_der[], cn);
        if (der_len <= 0)
        {
            NCryptDeleteKey(hncrypt, 0);
            return InternalResult.data_error;
        }

        CERT_NAME_BLOB subject_blob;
        subject_blob.cbData = cast(DWORD)der_len;
        subject_blob.pbData = name_der.ptr;

        // build SAN extension (Chrome requires SAN)
        ubyte[512] san_der = void;
        size_t pos = 2; // skip SEQUENCE header, fill in later

        void add_dns_name(scope const(char)[] name)
        {
            san_der[pos++] = 0x82; // dNSName [2] implicit
            san_der[pos++] = cast(ubyte)name.length;
            san_der[pos .. pos + name.length] = cast(const(ubyte)[])name[];
            pos += name.length;
        }

        void add_ip(scope const(ubyte)[] addr)
        {
            san_der[pos++] = 0x87; // iPAddress [7] implicit
            san_der[pos++] = cast(ubyte)addr.length;
            san_der[pos .. pos + addr.length] = addr[];
            pos += addr.length;
        }

        // CN as dNSName
        add_dns_name(cn);
        // localhost + loopback
        add_dns_name("localhost");
        add_ip([127, 0, 0, 1]);
        add_ip([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]); // ::1

        // hostname.local (mDNS)
        if (hostname.length > 0 && hostname.length + 6 < 128)
        {
            san_der[pos++] = 0x82;
            san_der[pos++] = cast(ubyte)(hostname.length + 6);
            san_der[pos .. pos + hostname.length] = cast(const(ubyte)[])hostname[];
            pos += hostname.length;
            san_der[pos .. pos + 6] = cast(const(ubyte)[])".local";
            pos += 6;
        }

        // TODO: add iPAddress SAN entries for all IP addresses the server is bound to.
        //       ...needs the server's bound addresses passed in or enumerated here!

        // SEQUENCE wrapper
        san_der[0] = 0x30;
        san_der[1] = cast(ubyte)(pos - 2);
        DWORD san_len = cast(DWORD)pos;

        CERT_EXTENSION san_ext;
        san_ext.pszObjId = cast(LPSTR)"2.5.29.17".ptr; // szOID_SUBJECT_ALT_NAME2
        san_ext.fCritical = FALSE;
        san_ext.Value.cbData = san_len;
        san_ext.Value.pbData = san_der.ptr;

        CERT_EXTENSIONS exts;
        exts.cExtension = 1;
        exts.rgExtension = &san_ext;

        // CertCreateSelfSignCertificate handles key association correctly for SChannel
        auto pctx = CertCreateSelfSignCertificate(hncrypt, &subject_blob, 0, null, null, null, null, &exts);
        if (pctx is null)
        {
            auto r = getlasterror_result();
            NCryptDeleteKey(hncrypt, 0);
            return r;
        }

        cert.context = pctx;
        cert.store = null;
        cert.hncrypt = hncrypt;

        return Result.success;
    }
    else
        assert(false);
}

private Result create_self_signed_portable(ref KeyPair key, out CertRef cert, const(char)[] cn, const(char)[] hostname, uint validity_days = 365)
{
    if (!key.valid)
        return InternalResult.invalid_parameter;

    Array!ubyte pub_x, pub_y;
    auto r = export_public_key_raw(key, pub_x, pub_y);
    if (!r)
        return r;

    auto now = getSysTime();
    auto not_before = getDateTime(now);
    auto not_after = getDateTime(now + dur!"days"(validity_days));

    // compute TBSCertificate field sizes
    ptrdiff_t ver_inner = der_integer_small(null, 2);
    ptrdiff_t ver = der_header(null, 0xa0, ver_inner) + ver_inner;
    ptrdiff_t serial = der_integer_small(null, 1);
    ptrdiff_t sig_alg_size = der_sig_alg(null);
    ptrdiff_t issuer = der_name_cn(null, cn);
    ptrdiff_t val_inner = der_utctime(null, not_before) + der_utctime(null, not_after);
    ptrdiff_t validity = der_header(null, 0x30, val_inner) + val_inner;
    ptrdiff_t subject = der_name_cn(null, cn);
    ptrdiff_t pubkey = der_ec_pubkey_info(null, pub_x[], pub_y[]);
    size_t tbs_content = ver + serial + sig_alg_size + issuer + validity + subject + pubkey;
    size_t tbs_total = der_header(null, 0x30, tbs_content) + tbs_content;

    // write TBSCertificate
    ubyte[512] tbs_buf = void;
    size_t pos = 0;
    pos += der_header(tbs_buf[pos .. $], 0x30, tbs_content);
    pos += der_header(tbs_buf[pos .. $], 0xa0, ver_inner);
    pos += der_integer_small(tbs_buf[pos .. $], 2);
    pos += der_integer_small(tbs_buf[pos .. $], 1);
    pos += der_sig_alg(tbs_buf[pos .. $]);
    pos += der_name_cn(tbs_buf[pos .. $], cn);
    pos += der_header(tbs_buf[pos .. $], 0x30, val_inner);
    pos += der_utctime(tbs_buf[pos .. $], not_before);
    pos += der_utctime(tbs_buf[pos .. $], not_after);
    pos += der_name_cn(tbs_buf[pos .. $], cn);
    pos += der_ec_pubkey_info(tbs_buf[pos .. $], pub_x[], pub_y[]);

    // hash and sign
    SHA256Context sha;
    sha_init(sha);
    sha_update(sha, tbs_buf[0 .. tbs_total]);
    ubyte[32] hash = sha_finalise(sha);

    Array!ubyte sig;
    r = sign_hash(key, hash[], sig);
    if (!r)
        return r;

    // Certificate: SEQUENCE { tbs, sigAlgId, BIT STRING { ecdsa_sig } }
    ptrdiff_t sig_der = der_ecdsa_sig(null, sig[]);
    size_t bs_content = 1 + sig_der; // unused_bits + ecdsa_sig
    size_t cert_content = tbs_total + sig_alg_size + 1 + der_length_size(bs_content) + bs_content;
    size_t cert_total = der_header(null, 0x30, cert_content) + cert_content;

    ubyte[640] cert_buf = void;
    pos = 0;
    pos += der_header(cert_buf[pos .. $], 0x30, cert_content);
    cert_buf[pos .. pos + tbs_total] = tbs_buf[0 .. tbs_total];
    pos += tbs_total;
    pos += der_sig_alg(cert_buf[pos .. $]);
    pos += der_header(cert_buf[pos .. $], 0x03, bs_content);
    cert_buf[pos++] = 0x00; // unused bits
    pos += der_ecdsa_sig(cert_buf[pos .. $], sig[]);

    return cert_buf[0 .. cert_total].load_certificate(cert);
}

Result load_certificate(const(ubyte)[] cert_data, out CertRef cert)
{
    version (Windows)
    {
        if (cert_data.length == 0)
            return InternalResult.invalid_parameter;

        const(ubyte)[] der = cert_data;
        Array!ubyte decoded;

        if (is_pem(cast(const(char)[])cert_data))
        {
            decoded = decode_pem(cast(const(char)[])cert_data);
            if (decoded.length == 0)
                return InternalResult.data_error;
            der = decoded[];
        }

        cert.store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, null);
        if (cert.store is null)
            return getlasterror_result();

        if (!CertAddEncodedCertificateToStore(cert.store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            der.ptr, cast(DWORD)der.length, CERT_STORE_ADD_REPLACE_EXISTING, cast(PCCERT_CONTEXT*)&cert.context))
        {
            auto r = getlasterror_result();
            CertCloseStore(cert.store, 0);
            cert.store = null;
            return r;
        }

        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Result associate_key(ref CertRef cert, ref KeyPair key)
{
    version (Windows)
    {
        if (!cert.valid || !key.valid)
            return InternalResult.invalid_parameter;

        // already associated (e.g., by CertCreateSelfSignCertificate)
        if (cert.hncrypt !is null)
            return Result.success;

        // SChannel requires the private key to be a named, persisted NCrypt key.
        // Ephemeral BCrypt/NCrypt keys cause SEC_E_NO_CREDENTIALS (0x8009030E).
        // Strategy: BCrypt blob → NCrypt temp (for PKCS8 export) → PKCS8 re-import
        // with key name → persisted key → CERT_KEY_PROV_INFO_PROP_ID so SChannel
        // can locate the key by provider + name.

        NCRYPT_PROV_HANDLE hprov;
        SECURITY_STATUS ss = NCryptOpenStorageProvider(&hprov, MS_KEY_STORAGE_PROVIDER.ptr, 0);
        if (ss != 0)
            return Result(cast(uint)ss);

        // export BCrypt key as blob
        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(key.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, null, 0, &blob_size, 0);
        if (status != 0)
        {
            NCryptFreeObject(hprov);
            return Result(cast(uint)status);
        }

        auto blob = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(key.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, blob.ptr, blob_size, &blob_size, 0);
        if (status != 0)
        {
            NCryptFreeObject(hprov);
            return Result(cast(uint)status);
        }

        // import BCrypt blob into NCrypt (unfinalized so we can set export policy)
        NCRYPT_KEY_HANDLE htemp;
        ss = NCryptImportKey(hprov, null, BCRYPT_ECCPRIVATE_BLOB.ptr, null, &htemp, blob.ptr, blob_size, NCRYPT_DO_NOT_FINALIZE_FLAG);
        if (ss != 0)
        {
            NCryptFreeObject(hprov);
            return Result(cast(uint)ss);
        }

        // allow plaintext export so we can re-export as PKCS8
        DWORD export_policy = NCRYPT_ALLOW_EXPORT_FLAG | NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG;
        ss = NCryptSetProperty(htemp, NCRYPT_EXPORT_POLICY_PROPERTY.ptr, cast(ubyte*)&export_policy, DWORD.sizeof, 0);
        if (ss != 0)
        {
            NCryptFreeObject(htemp);
            NCryptFreeObject(hprov);
            return Result(cast(uint)ss);
        }

        ss = NCryptFinalizeKey(htemp, 0);
        if (ss != 0)
        {
            NCryptFreeObject(htemp);
            NCryptFreeObject(hprov);
            return Result(cast(uint)ss);
        }

        // export as PKCS8 — only PKCS8 supports named key import for persistence
        ULONG pkcs8_size = 0;
        ss = NCryptExportKey(htemp, null, NCRYPT_PKCS8_PRIVATE_KEY_BLOB.ptr, null, null, 0, &pkcs8_size, 0);
        if (ss != 0)
        {
            NCryptFreeObject(htemp);
            NCryptFreeObject(hprov);
            return Result(cast(uint)ss);
        }

        auto pkcs8 = Array!ubyte(Alloc, pkcs8_size);
        ss = NCryptExportKey(htemp, null, NCRYPT_PKCS8_PRIVATE_KEY_BLOB.ptr, null, pkcs8.ptr, pkcs8_size, &pkcs8_size, 0);
        NCryptFreeObject(htemp);
        if (ss != 0)
        {
            NCryptFreeObject(hprov);
            return Result(cast(uint)ss);
        }

        // re-import PKCS8 with key name to create a persisted key
        wchar[48] name_buf = void;
        size_t name_len = generate_key_name(name_buf[]);

        NCryptBuffer nbuf;
        nbuf.cbBuffer = cast(uint)((name_len + 1) * 2); // include null terminator, in bytes
        nbuf.BufferType = NCRYPTBUFFER_PKCS_KEY_NAME;
        nbuf.pvBuffer = cast(void*)name_buf.ptr;

        NCryptBufferDesc params;
        params.ulVersion = 0; // NCRYPTBUFFER_VERSION
        params.cBuffers = 1;
        params.pBuffers = &nbuf;

        NCRYPT_KEY_HANDLE hkey;
        ss = NCryptImportKey(hprov, null, NCRYPT_PKCS8_PRIVATE_KEY_BLOB.ptr, &params, &hkey, pkcs8.ptr, pkcs8_size, NCRYPT_OVERWRITE_KEY_FLAG);
        NCryptFreeObject(hprov);
        if (ss != 0)
            return Result(cast(uint)ss);

        // clean up any previously associated NCrypt key
        if (cert.hncrypt !is null)
            NCryptDeleteKey(cert.hncrypt, 0);
        cert.hncrypt = hkey;

        // tell SChannel where to find the key: provider name + key name (CNG mode)
        CRYPT_KEY_PROV_INFO prov_info;
        prov_info.pwszContainerName = name_buf.ptr;
        prov_info.pwszProvName = cast(wchar*)MS_KEY_STORAGE_PROVIDER.ptr;
        prov_info.dwProvType = 0; // CNG key storage provider
        prov_info.dwFlags = 0;
        prov_info.cProvParam = 0;
        prov_info.rgProvParam = null;
        prov_info.dwKeySpec = 0;

        if (!CertSetCertificateContextProperty(cert.context, CERT_KEY_PROV_INFO_PROP_ID, 0, &prov_info))
        {
            auto r = getlasterror_result();
            NCryptDeleteKey(cert.hncrypt, 0);
            cert.hncrypt = null;
            return r;
        }

        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

void free_cert(ref CertRef cert)
{
    version (Windows)
    {
        if (cert.hncrypt !is null)
            NCryptDeleteKey(cert.hncrypt, 0);
        if (cert.context !is null)
            CertFreeCertificateContext(cert.context);
        if (cert.store !is null)
            CertCloseStore(cert.store, 0);
        cert.hncrypt = null;
        cert.context = null;
        cert.store = null;
    }
}

SysTime cert_expiry(ref const CertRef cert)
{
    version (Windows)
    {
        if (cert.context is null || cert.context.pCertInfo is null)
            return SysTime();
        return SysTime(*cast(ulong*)&cert.context.pCertInfo.NotAfter);
    }
    else
        return SysTime();
}

inout(void)* native_cert_context(ref inout CertRef cert)
{
    version (Windows)
        return cast(inout(void)*)cert.context;
    else
        return null;
}


Result sign_hash(ref KeyPair kp, const(ubyte)[] hash, out Array!ubyte signature)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG sig_size = 0;
        NTSTATUS status = BCryptSignHash(kp.hcng, null, cast(PUCHAR)hash.ptr, cast(ULONG)hash.length, null, 0, &sig_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        signature = Array!ubyte(Alloc, sig_size);
        status = BCryptSignHash(kp.hcng, null, cast(PUCHAR)hash.ptr, cast(ULONG)hash.length, signature.ptr, sig_size, &sig_size, 0);
        if (status != 0)
        {
            signature = Array!ubyte();
            return Result(cast(uint)status);
        }

        signature.resize(sig_size);
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Result export_public_key_raw(ref KeyPair kp, out Array!ubyte x, out Array!ubyte y)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr, null, 0, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        auto blob = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr, blob.ptr, blob_size, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        if (blob_size < 8)
            return InternalResult.data_error;

        auto hdr = cast(BCRYPT_ECCKEY_BLOB*)blob.ptr;
        ULONG key_len = hdr.cbKey;
        if (blob_size < 8 + 2 * key_len)
            return InternalResult.data_error;

        x = blob[8 .. 8 + key_len];
        y = blob[8 + key_len .. 8 + 2 * key_len];
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}


Array!ubyte generate_csr(ref KeyPair kp, const(char)[] cn)
{
    if (!kp.valid)
        return Array!ubyte();

    Array!ubyte pub_x, pub_y;
    if (!export_public_key_raw(kp, pub_x, pub_y))
        return Array!ubyte();

    // compute CertificationRequestInfo field sizes
    ptrdiff_t ver = der_integer_small(null, 0);
    ptrdiff_t subject = der_name_cn(null, cn);
    ptrdiff_t pubkey = der_ec_pubkey_info(null, pub_x[], pub_y[]);
    ptrdiff_t attrs = der_header(null, 0xa0, 0); // empty attributes [0]
    size_t info_content = ver + subject + pubkey + attrs;
    size_t info_total = der_header(null, 0x30, info_content) + info_content;

    // write CertificationRequestInfo
    ubyte[512] info_buf = void;
    size_t pos = 0;
    pos += der_header(info_buf[pos .. $], 0x30, info_content);
    pos += der_integer_small(info_buf[pos .. $], 0);
    pos += der_name_cn(info_buf[pos .. $], cn);
    pos += der_ec_pubkey_info(info_buf[pos .. $], pub_x[], pub_y[]);
    pos += der_header(info_buf[pos .. $], 0xa0, 0);

    // hash and sign
    SHA256Context sha;
    sha_init(sha);
    sha_update(sha, info_buf[0 .. info_total]);
    ubyte[32] hash = sha_finalise(sha);

    Array!ubyte sig;
    if (!sign_hash(kp, hash[], sig))
        return Array!ubyte();

    // CertificationRequest: SEQUENCE { info, sigAlgId, BIT STRING { ecdsa_sig } }
    ptrdiff_t sig_alg_size = der_sig_alg(null);
    ptrdiff_t sig_der = der_ecdsa_sig(null, sig[]);
    size_t bs_content = 1 + sig_der;
    size_t csr_content = info_total + sig_alg_size + 1 + der_length_size(bs_content) + bs_content;
    size_t csr_total = der_header(null, 0x30, csr_content) + csr_content;

    auto csr = Array!ubyte(Alloc, csr_total);
    pos = 0;
    pos += der_header(csr[pos .. $], 0x30, csr_content);
    csr.ptr[pos .. pos + info_total] = info_buf[0 .. info_total];
    pos += info_total;
    pos += der_sig_alg(csr[pos .. $]);
    pos += der_header(csr[pos .. $], 0x03, bs_content);
    csr.ptr[pos++] = 0x00;
    pos += der_ecdsa_sig(csr[pos .. $], sig[]);

    return csr;
}


Result export_private_key(ref KeyPair kp, out Array!ubyte key_out)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, null, 0, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        key_out = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, key_out.ptr, blob_size, &blob_size, 0);
        if (status != 0)
        {
            key_out.clear();
            return Result(cast(uint)status);
        }

        key_out.resize(blob_size);
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Result import_private_key(const(ubyte)[] key_data, out KeyPair kp)
{
    version (Windows)
    {
        const(ubyte)[] der = key_data;
        Array!ubyte decoded;

        if (is_pem(cast(const(char)[])key_data))
        {
            decoded = decode_pem(cast(const(char)[])key_data);
            if (decoded.length == 0)
                return InternalResult.data_error;
            der = decoded[];
        }

        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);

        status = BCryptImportKeyPair(kp.halg, null, BCRYPT_ECCPRIVATE_BLOB.ptr, &kp.hcng, cast(ubyte*)der.ptr, cast(ULONG)der.length, 0);
        if (status != 0)
        {
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return Result(cast(uint)status);
        }

        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}


private:

version (Windows)
{
    size_t generate_key_name(wchar[] buf)
    {
        import urt.mem.temp : tconcat;
        import urt.string.uni : uni_convert;
        __gshared uint counter = 0;
        size_t len = uni_convert(tconcat("openwatt_key_", counter++), buf);
        buf[len] = 0;
        return len;
    }
}

version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    import core.sys.windows.wincrypt;
    import core.sys.windows.windef;

    pragma(lib, "Bcrypt");
    pragma(lib, "Crypt32");
    pragma(lib, "Ncrypt");

    alias SECURITY_STATUS = int;
    alias NCRYPT_PROV_HANDLE = void*;
    alias NCRYPT_KEY_HANDLE = void*;

    enum NCRYPT_OVERWRITE_KEY_FLAG = 0x00000080;
    enum NCRYPT_DO_NOT_FINALIZE_FLAG = 0x00000400;
    enum NCRYPT_ALLOW_EXPORT_FLAG = 0x00000001;
    enum NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG = 0x00000002;
    enum DWORD CERT_KEY_PROV_INFO_PROP_ID = 2;
    enum DWORD NCRYPTBUFFER_PKCS_KEY_NAME = 45;

    enum LPCSTR CERT_STORE_PROV_MEMORY = cast(LPCSTR)2;
    enum DWORD CERT_STORE_ADD_REPLACE_EXISTING = 3;

    struct CERT_EXTENSIONS
    {
        DWORD cExtension;
        PCERT_EXTENSION rgExtension;
    }

    immutable wchar[] MS_KEY_STORAGE_PROVIDER = "Microsoft Software Key Storage Provider\0"w;
    immutable wchar[] NCRYPT_PKCS8_PRIVATE_KEY_BLOB = "PKCS8_PRIVATEKEY\0"w;
    immutable wchar[] NCRYPT_EXPORT_POLICY_PROPERTY = "Export Policy\0"w;


    struct CRYPT_KEY_PROV_INFO
    {
        wchar* pwszContainerName;
        wchar* pwszProvName;
        DWORD dwProvType;
        DWORD dwFlags;
        DWORD cProvParam;
        void* rgProvParam;
        DWORD dwKeySpec;
    }

    struct NCryptBuffer
    {
        ULONG cbBuffer;
        ULONG BufferType;
        void* pvBuffer;
    }

    struct NCryptBufferDesc
    {
        ULONG ulVersion;
        ULONG cBuffers;
        NCryptBuffer* pBuffers;
    }

    extern (Windows) @nogc nothrow
    {
        BOOL CertAddEncodedCertificateToStore(
            HCERTSTORE hCertStore,
            DWORD dwCertEncodingType,
            const(BYTE)* pbCertEncoded,
            DWORD cbCertEncoded,
            DWORD dwAddDisposition,
            PCCERT_CONTEXT* ppCertContext
        );

        BOOL CertSetCertificateContextProperty(
            PCCERT_CONTEXT pCertContext,
            DWORD dwPropId,
            DWORD dwFlags,
            const(void)* pvData
        );

        SECURITY_STATUS NCryptOpenStorageProvider(
            NCRYPT_PROV_HANDLE* phProvider,
            const(wchar)* pszProviderName,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptImportKey(
            NCRYPT_PROV_HANDLE hProvider,
            NCRYPT_KEY_HANDLE hImportKey,
            const(wchar)* pszBlobType,
            void* pParameterList, // NCryptBufferDesc*
            NCRYPT_KEY_HANDLE* phKey,
            BYTE* pbData,
            DWORD cbData,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptFreeObject(
            NCRYPT_PROV_HANDLE hObject
        );

        SECURITY_STATUS NCryptSetProperty(
            NCRYPT_KEY_HANDLE hObject,
            const(wchar)* pszProperty,
            ubyte* pbInput,
            DWORD cbInput,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptFinalizeKey(
            NCRYPT_KEY_HANDLE hKey,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptExportKey(
            NCRYPT_KEY_HANDLE hKey,
            NCRYPT_KEY_HANDLE hExportKey,
            const(wchar)* pszBlobType,
            void* pParameterList,
            BYTE* pbOutput,
            DWORD cbOutput,
            DWORD* pcbResult,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptCreatePersistedKey(
            NCRYPT_PROV_HANDLE hProvider,
            NCRYPT_KEY_HANDLE* phKey,
            const(wchar)* pszAlgId,
            const(wchar)* pszKeyName,
            DWORD dwLegacyKeySpec,
            DWORD dwFlags
        );

        SECURITY_STATUS NCryptDeleteKey(
            NCRYPT_KEY_HANDLE hKey,
            DWORD dwFlags
        );

        PCCERT_CONTEXT CertCreateSelfSignCertificate(
            NCRYPT_KEY_HANDLE hCryptProvOrNCryptKey,
            CERT_NAME_BLOB* pSubjectIssuerBlob,
            DWORD dwFlags,
            void* pKeyProvInfo, // PCRYPT_KEY_PROV_INFO
            void* pSignatureAlgorithm, // PCRYPT_ALGORITHM_IDENTIFIER
            void* pStartTime, // PSYSTEMTIME
            void* pEndTime, // PSYSTEMTIME
            void* pExtensions // PCERT_EXTENSIONS
        );
    }
}
