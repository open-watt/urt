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
    else version (Posix)
    {
        mbedtls_pk_context pk;
    }
    else version (FreeStanding)
    {
        // PKI backend not yet implemented for bare-metal
        void* _stub;
    }
    else
        static assert(false, "TODO");

    bool valid() const pure
    {
        version (Windows)
            return hcng !is null;
        else version (Posix)
            return pk.pk_info !is null;
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
    else version (Posix)
    {
        mbedtls_x509_crt* crt;     // heap-allocated via urt_x509_crt_new
    }

    bool valid() const pure
    {
        version (Windows)
            return context !is null;
        else version (Posix)
            return crt !is null;
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
    {
        mbedtls_pk_init(&kp.pk);
        int ret = urt_pk_gen_ec_p256_key(&kp.pk, &mbedtls_ctr_drbg_random, get_rng());
        if (ret != 0)
        {
            mbedtls_pk_free(&kp.pk);
            kp.pk = mbedtls_pk_context.init;
            return Result(cast(uint)ret);
        }

        return Result.success;
    }
    else
        assert(0, "PKI: generate_keypair not implemented for this platform");
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
    else version (Posix)
    {
        mbedtls_pk_free(&kp.pk);
        kp.pk = mbedtls_pk_context.init;
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
    {
        if (cert_data.length == 0)
            return InternalResult.invalid_parameter;

        cert.crt = urt_x509_crt_new();
        if (cert.crt is null)
            return InternalResult.invalid_parameter;

        // mbedtls_x509_crt_parse handles both PEM and DER.
        // for PEM, the buffer must be null-terminated.
        int ret;
        if (is_pem(cast(const(char)[])cert_data))
        {
            // add null terminator for mbedtls PEM parser
            auto pem_buf = Array!ubyte(Alloc, cert_data.length + 1);
            pem_buf.ptr[0 .. cert_data.length] = cert_data[];
            pem_buf.ptr[cert_data.length] = 0;
            ret = mbedtls_x509_crt_parse(cert.crt, pem_buf.ptr, pem_buf.length);
        }
        else
            ret = mbedtls_x509_crt_parse_der(cert.crt, cert_data.ptr, cert_data.length);

        if (ret != 0)
        {
            urt_x509_crt_delete(cert.crt);
            cert.crt = null;
            return Result(cast(uint)ret);
        }

        return Result.success;
    }
    else
        assert(0, "PKI: not implemented for this platform");
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
    {
        // no-op: mbedtls doesn't require key-to-cert binding in a system store.
        // the cert and key are passed separately to mbedtls_ssl_conf_own_cert.
        if (!cert.valid || !key.valid)
            return InternalResult.invalid_parameter;
        return Result.success;
    }
    else
        assert(0, "PKI: not implemented for this platform");
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
    else version (Posix)
    {
        if (cert.crt !is null)
            urt_x509_crt_delete(cert.crt);
        cert.crt = null;
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
    else version (Posix)
    {
        // TODO: parse cert.crt.valid_to (mbedtls_x509_time) and convert to SysTime
        return SysTime();
    }
    else
        return SysTime();
}

inout(void)* native_cert_context(ref inout CertRef cert)
{
    version (Windows)
        return cast(inout(void)*)cert.context;
    else version (Posix)
        return cast(inout(void)*)cert.crt;
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
    {
        if (!kp.valid)
            return InternalResult.invalid_parameter;

        // mbedtls_pk_sign produces DER-encoded ECDSA signature.
        // we need raw R||S format (64 bytes for P-256) to match the Windows contract.
        ubyte[256] sig_buf = void;
        size_t sig_len = 0;
        int ret = urt_pk_sign(&kp.pk,
            hash.ptr, hash.length, sig_buf.ptr, sig_buf.length, &sig_len,
            &mbedtls_ctr_drbg_random, get_rng());
        if (ret != 0)
            return Result(cast(uint)ret);

        // parse DER SEQUENCE { INTEGER r, INTEGER s } → raw R||S (32 bytes each)
        signature = Array!ubyte(Alloc, 64);
        if (!der_sig_to_raw(sig_buf[0 .. sig_len], signature.ptr[0 .. 64]))
        {
            signature = Array!ubyte();
            return InternalResult.data_error;
        }

        return Result.success;
    }
    else
        assert(0, "PKI: not implemented for this platform");
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
    {
        if (!kp.valid)
            return InternalResult.invalid_parameter;

        // export uncompressed point: 0x04 || X || Y
        ubyte[65] pt_buf = void; // 1 + 32 + 32 for P-256
        size_t olen = 0;
        int ret = urt_pk_export_pubkey_xy(&kp.pk, pt_buf.ptr, pt_buf.length, &olen);
        if (ret != 0)
            return Result(cast(uint)ret);

        if (olen != 65) // 0x04 + 32 + 32
            return InternalResult.data_error;

        x = Array!ubyte(Alloc, 32);
        y = Array!ubyte(Alloc, 32);
        x.ptr[0 .. 32] = pt_buf[1 .. 33];
        y.ptr[0 .. 32] = pt_buf[33 .. 65];
        return Result.success;
    }
    else
        assert(0, "PKI: not implemented for this platform");
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

        // Export BCrypt blob: BCRYPT_ECCKEY_BLOB { magic, cbKey=32 } X[32] Y[32] d[32]
        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, null, 0, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        auto blob = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr, blob.ptr, blob_size, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        if (blob_size < 8 + 32 * 3)
            return InternalResult.data_error;

        // Build SEC 1 ECPrivateKey DER from the BCrypt blob components
        return build_ec_sec1_der(blob[72 .. 104][0..32], blob[8 .. 40][0..32], blob[40 .. 72][0..32], key_out);
    }
    else version (Posix)
    {
        if (!kp.valid)
            return InternalResult.invalid_parameter;

        // Extract raw d, X, Y from mbedtls pk context
        ubyte[32] d = void;
        ubyte[65] xy_buf = void;
        size_t d_len = 0, xy_len = 0;

        int ret = urt_pk_export_privkey_d(&kp.pk, d.ptr, d.length, &d_len);
        if (ret != 0)
            return Result(cast(uint)ret);

        ret = urt_pk_export_pubkey_xy(&kp.pk, xy_buf.ptr, xy_buf.length, &xy_len);
        if (ret != 0)
            return Result(cast(uint)ret);

        // xy_buf is 0x04 || X[32] || Y[32]
        return build_ec_sec1_der(d, xy_buf[1 .. 33], xy_buf[33 .. 65], key_out);
    }
    else
        assert(0, "PKI: not implemented for this platform");
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

        ubyte[32] d = void, x = void, y = void;
        if (!parse_ec_sec1_der(der, d, x, y))
            return InternalResult.data_error;

        // Build BCRYPT_ECCKEY_BLOB: { magic(4), cbKey(4)=32 } X[32] Y[32] d[32]
        ubyte[104] blob = void;
        (cast(uint[])blob[0 .. 8])[0] = 0x34534345; // BCRYPT_ECDSA_PRIVATE_P256_MAGIC
        (cast(uint[])blob[0 .. 8])[1] = 32;          // cbKey
        blob[8 .. 40] = x[];
        blob[40 .. 72] = y[];
        blob[72 .. 104] = d[];

        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status == 0)
        {
            status = BCryptImportKeyPair(kp.halg, null, BCRYPT_ECCPRIVATE_BLOB.ptr, &kp.hcng, blob.ptr, 104, 0);
            if (status == 0)
                return Result.success;
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
        }
        return Result(cast(uint)status);
    }
    else version (Posix)
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

        ubyte[32] d = void, x = void, y = void;
        if (!parse_ec_sec1_der(der, d, x, y))
            return InternalResult.data_error;

        // Build uncompressed point: 0x04 || X || Y
        ubyte[65] xy = void;
        xy[0] = 0x04;
        xy[1 .. 33] = x[];
        xy[33 .. 65] = y[];

        mbedtls_pk_init(&kp.pk);
        int ret = urt_pk_import_ec_p256_key(&kp.pk, d.ptr, d.length, xy.ptr, xy.length);
        if (ret != 0)
        {
            mbedtls_pk_free(&kp.pk);
            kp.pk = mbedtls_pk_context.init;
            return Result(cast(uint)ret);
        }

        return Result.success;
    }
    else
        assert(0, "PKI: not implemented for this platform");
}

private:

// Build SEC 1 ECPrivateKey DER (RFC 5915) for P-256 from raw components.
// Both platforms use this format for portable key storage.
//
// ECPrivateKey ::= SEQUENCE {
//   INTEGER 1,
//   OCTET STRING d[32],
//   [0] { OID secp256r1 },
//   [1] { BIT STRING 04 || X || Y }
// }
Result build_ec_sec1_der(ref const ubyte[32] d, ref const ubyte[32] x, ref const ubyte[32] y, out Array!ubyte key_out)
{
    // compute sizes (pass null to measure)
    size_t ver_size = der_integer_small(null, 1);                           // INTEGER 1
    size_t d_size = der_tlv(null, 0x04, d[]);                              // OCTET STRING d
    size_t oid_size = der_tlv(null, 0x06, oid_prime256v1[]);               // OID secp256r1
    size_t params_size = der_header(null, 0xa0, oid_size) + oid_size;      // [0] { OID }

    enum size_t pt_len = 1 + 32 + 32;                                     // 04 || X || Y
    enum size_t bs_content = 1 + pt_len;                                   // unused_bits + point
    size_t bs_size = der_header(null, 0x03, bs_content) + bs_content;      // BIT STRING
    size_t pubkey_size = der_header(null, 0xa1, bs_size) + bs_size;        // [1] { BIT STRING }

    size_t content = ver_size + d_size + params_size + pubkey_size;
    size_t total = der_header(null, 0x30, content) + content;              // outer SEQUENCE

    key_out = Array!ubyte(Alloc, total);
    ubyte[] buf = key_out[];
    size_t pos = 0;

    pos += der_header(buf[pos .. $], 0x30, content);
    pos += der_integer_small(buf[pos .. $], 1);
    pos += der_tlv(buf[pos .. $], 0x04, d[]);

    // [0] EXPLICIT { OID secp256r1 }
    pos += der_header(buf[pos .. $], 0xa0, oid_size);
    pos += der_tlv(buf[pos .. $], 0x06, oid_prime256v1[]);

    // [1] EXPLICIT { BIT STRING { 04 || X || Y } }
    pos += der_header(buf[pos .. $], 0xa1, bs_size);
    pos += der_header(buf[pos .. $], 0x03, bs_content);
    buf[pos++] = 0x00;  // unused bits
    buf[pos++] = 0x04;  // uncompressed point
    buf[pos .. pos + 32] = x[];
    pos += 32;
    buf[pos .. pos + 32] = y[];
    pos += 32;

    assert(pos == total);
    return Result.success;
}

// Parse SEC 1 ECPrivateKey DER (RFC 5915) for P-256, extracting raw d, X, Y.
bool parse_ec_sec1_der(const(ubyte)[] der, ref ubyte[32] d, ref ubyte[32] x, ref ubyte[32] y)
{
    if (der.length < 2 || der[0] != 0x30)
        return false;

    size_t pos = 1;
    size_t seq_len;
    if (!read_der_length(der, pos, seq_len))
        return false;
    if (pos + seq_len > der.length)
        return false;
    size_t seq_end = pos + seq_len;

    // INTEGER 1 (version)
    if (pos + 3 > seq_end || der[pos] != 0x02 || der[pos + 1] != 0x01 || der[pos + 2] != 0x01)
        return false;
    pos += 3;

    // OCTET STRING (private key d)
    if (pos >= seq_end || der[pos] != 0x04)
        return false;
    ++pos;
    size_t d_len;
    if (!read_der_length(der, pos, d_len))
        return false;
    if (d_len == 0 || d_len > 32 || pos + d_len > seq_end)
        return false;
    d[] = 0;
    d[32 - d_len .. 32] = der[pos .. pos + d_len];  // right-align
    pos += d_len;

    // optional [0] parameters — skip
    if (pos < seq_end && der[pos] == 0xa0)
    {
        ++pos;
        size_t param_len;
        if (!read_der_length(der, pos, param_len))
            return false;
        pos += param_len;
    }

    // optional [1] public key
    if (pos < seq_end && der[pos] == 0xa1)
    {
        ++pos;
        size_t ctx_len;
        if (!read_der_length(der, pos, ctx_len))
            return false;
        size_t ctx_end = pos + ctx_len;
        // BIT STRING
        if (pos >= ctx_end || der[pos] != 0x03)
            return false;
        ++pos;
        size_t bs_len;
        if (!read_der_length(der, pos, bs_len))
            return false;
        // unused bits (0) + 04 + X + Y = 66 bytes
        if (bs_len != 66 || pos + bs_len > ctx_end)
            return false;
        if (der[pos] != 0x00 || der[pos + 1] != 0x04)
            return false;
        x[] = der[pos + 2 .. pos + 34];
        y[] = der[pos + 34 .. pos + 66];
        return true;
    }

    // No public key in the SEC 1 structure — can't reconstruct without EC math
    return false;
}

bool read_der_length(const(ubyte)[] der, ref size_t pos, out size_t len)
{
    if (pos >= der.length)
        return false;
    ubyte b = der[pos++];
    if (b < 0x80)
    {
        len = b;
        return true;
    }
    uint n = b & 0x7f;
    if (n == 0 || n > 2 || pos + n > der.length)
        return false;
    len = 0;
    for (uint i = 0; i < n; ++i)
        len = (len << 8) | der[pos++];
    return true;
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

    extern(Windows) @nogc nothrow
    {
        BOOL CertAddEncodedCertificateToStore(HCERTSTORE hCertStore, DWORD dwCertEncodingType, const(BYTE)* pbCertEncoded, DWORD cbCertEncoded, DWORD dwAddDisposition, PCCERT_CONTEXT* ppCertContext);
        BOOL CertSetCertificateContextProperty(PCCERT_CONTEXT pCertContext, DWORD dwPropId, DWORD dwFlags, const(void)* pvData);
        SECURITY_STATUS NCryptOpenStorageProvider(NCRYPT_PROV_HANDLE* phProvider, const(wchar)* pszProviderName, DWORD dwFlags);
        SECURITY_STATUS NCryptImportKey(NCRYPT_PROV_HANDLE hProvider, NCRYPT_KEY_HANDLE hImportKey, const(wchar)* pszBlobType, void* pParameterList, NCRYPT_KEY_HANDLE* phKey, BYTE* pbData, DWORD cbData, DWORD dwFlags);
        SECURITY_STATUS NCryptFreeObject(NCRYPT_PROV_HANDLE hObject);
        SECURITY_STATUS NCryptSetProperty(NCRYPT_KEY_HANDLE hObject, const(wchar)* pszProperty, ubyte* pbInput, DWORD cbInput, DWORD dwFlags);
        SECURITY_STATUS NCryptFinalizeKey(NCRYPT_KEY_HANDLE hKey, DWORD dwFlags);
        SECURITY_STATUS NCryptExportKey(NCRYPT_KEY_HANDLE hKey, NCRYPT_KEY_HANDLE hExportKey, const(wchar)* pszBlobType, void* pParameterList, BYTE* pbOutput, DWORD cbOutput, DWORD* pcbResult, DWORD dwFlags);
        SECURITY_STATUS NCryptCreatePersistedKey(NCRYPT_PROV_HANDLE hProvider, NCRYPT_KEY_HANDLE* phKey, const(wchar)* pszAlgId, const(wchar)* pszKeyName, DWORD dwLegacyKeySpec, DWORD dwFlags);
        SECURITY_STATUS NCryptDeleteKey(NCRYPT_KEY_HANDLE hKey, DWORD dwFlags);

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

version (Posix)
{
    import urt.internal.mbedtls;

    // lazily-initialized global CSPRNG for mbedtls operations
    mbedtls_ctr_drbg_context* get_rng()
    {
        __gshared mbedtls_ctr_drbg_context* rng;
        __gshared mbedtls_entropy_context* entropy;
        __gshared bool initialized;

        if (initialized)
            return rng;

        entropy = urt_entropy_new();
        if (entropy is null)
            return null;

        rng = urt_ctr_drbg_new();
        if (rng is null)
        {
            urt_entropy_delete(entropy);
            entropy = null;
            return null;
        }

        int ret = mbedtls_ctr_drbg_seed(rng, &mbedtls_entropy_func, cast(void*)entropy, null, 0);
        if (ret != 0)
        {
            urt_ctr_drbg_delete(rng);
            urt_entropy_delete(entropy);
            rng = null;
            entropy = null;
            return null;
        }

        initialized = true;
        return rng;
    }

    // convert DER-encoded ECDSA signature SEQUENCE { INTEGER r, INTEGER s }
    // to raw R||S format (32 bytes each for P-256)
    bool der_sig_to_raw(const(ubyte)[] der, ubyte[] raw)
    {
        if (raw.length < 64)
            return false;

        raw[0 .. 64] = 0;

        size_t pos = 0;

        // SEQUENCE
        if (pos >= der.length || der[pos++] != 0x30)
            return false;
        if (pos >= der.length)
            return false;

        // sequence length (skip)
        if (der[pos] & 0x80)
            pos += 1 + (der[pos] & 0x7f);
        else
            ++pos;

        // parse two INTEGERs into raw[0..32] and raw[32..64]
        foreach (i; 0 .. 2)
        {
            if (pos >= der.length || der[pos++] != 0x02)
                return false;
            if (pos >= der.length)
                return false;

            size_t len = der[pos++];
            if (pos + len > der.length)
                return false;

            auto integer = der[pos .. pos + len];
            pos += len;

            // strip leading zero padding (DER INTEGERs are signed, so positive values
            // with high bit set get a 0x00 prefix)
            while (integer.length > 32 && integer[0] == 0)
                integer = integer[1 .. $];

            if (integer.length > 32)
                return false;

            // right-align into 32-byte field
            size_t offset = 32 - integer.length;
            raw[i * 32 + offset .. i * 32 + offset + integer.length] = integer[];
        }

        return true;
    }
}
