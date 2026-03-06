module urt.crypto.pki;

import urt.array;
import urt.encoding;
import urt.mem;
import urt.result;
import urt.string;
import urt.time;

nothrow @nogc:

//version = DebugPKI;

enum KeyType
{
    rsa2048,
    ecdsa_p256,
}

struct KeyPair
{
nothrow @nogc:
    version (Windows)
    {
        // CAPI handles (RSA)
        HCRYPTPROV hprov;
        HCRYPTKEY hkey;
        // CNG handles (ECDSA)
        BCRYPT_ALG_HANDLE halg;
        BCRYPT_KEY_HANDLE hcng;
    }

    KeyType type;

    bool valid() const pure
    {
        version (Windows)
            return hprov != 0 || hcng !is null;
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
    }

    bool valid() const pure
    {
        version (Windows)
            return context !is null;
        else
            return false;
    }
}


Result generate_keypair(ref KeyPair kp, KeyType type)
{
    version (Windows)
    {
        DWORD prov_type;
        ALG_ID alg;
        DWORD flags;

        final switch (type)
        {
            case KeyType.rsa2048:
                prov_type = PROV_RSA_AES;
                alg = AT_KEYEXCHANGE;
                flags = (2048 << 16) | CRYPT_EXPORTABLE;
                break;

            case KeyType.ecdsa_p256:
                return generate_ecdsa_p256(kp);
        }

        // Use a named container (not CRYPT_VERIFYCONTEXT) so private key is
        // accessible for signing operations like CSR generation.
        if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, prov_type, CRYPT_NEWKEYSET))
        {
            // Container already exists, open it
            if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, prov_type, 0))
                return getlasterror_result();
        }

        if (!CryptGenKey(kp.hprov, alg, flags, &kp.hkey))
        {
            auto r = getlasterror_result();
            CryptReleaseContext(kp.hprov, 0);
            kp.hprov = 0;
            return r;
        }

        kp.type = KeyType.rsa2048;
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
        if (kp.hkey != 0)
            CryptDestroyKey(kp.hkey);
        if (kp.hprov != 0)
            CryptReleaseContext(kp.hprov, 0);
        if (kp.hcng !is null)
            BCryptDestroyKey(kp.hcng);
        if (kp.halg !is null)
            BCryptCloseAlgorithmProvider(kp.halg, 0);
        kp.hkey = 0;
        kp.hprov = 0;
        kp.hcng = null;
        kp.halg = null;
    }
}

Result create_self_signed(ref CertRef cert, ref KeyPair key, const(char)[] cn, uint validity_days = 365)
{
    version (Windows)
    {
        if (!key.valid)
            return InternalResult.invalid_parameter;

        char[256] cn_buf = void;
        if (cn.length + 3 >= cn_buf.length)
            return InternalResult.buffer_too_small;
        cn_buf[0 .. 3] = "CN=";
        cn_buf[3 .. 3 + cn.length] = cn[];
        cn_buf[3 + cn.length] = 0;

        ubyte[256] name_buf = void;
        DWORD name_size = name_buf.sizeof;
        if (!CertStrToNameA(X509_ASN_ENCODING, cn_buf.ptr, CERT_X500_NAME_STR, null, name_buf.ptr, &name_size, null))
            return getlasterror_result();

        CERT_NAME_BLOB subject_blob;
        subject_blob.cbData = name_size;
        subject_blob.pbData = name_buf.ptr;

        CRYPT_KEY_PROV_INFO key_prov_info;
        key_prov_info.pwszContainerName = null;
        key_prov_info.pwszProvName = null;
        key_prov_info.dwProvType = PROV_RSA_AES;
        key_prov_info.dwKeySpec = AT_KEYEXCHANGE;

        SYSTEMTIME start_time = void, end_time = void;
        GetSystemTime(&start_time);
        end_time = start_time;

        FILETIME ft_start = void;
        SystemTimeToFileTime(&start_time, &ft_start);
        ulong ticks = *cast(ulong*)&ft_start;
        ticks += cast(ulong)validity_days * 24 * 60 * 60 * 10_000_000; // 100ns ticks per day
        FILETIME ft_end = *cast(FILETIME*)&ticks;
        FileTimeToSystemTime(&ft_end, &end_time);

        PCCERT_CONTEXT ctx = CertCreateSelfSignCertificate(
            key.hprov,
            &subject_blob,
            0,
            &key_prov_info,
            null,
            &start_time,
            &end_time,
            null
        );

        if (ctx is null)
            return getlasterror_result();

        cert.context = ctx;
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Result load_certificate(ref CertRef cert, const(ubyte)[] cert_data)
{
    version (Windows)
    {
        if (cert_data.length == 0)
            return InternalResult.invalid_parameter;

        const(ubyte)[] der = cert_data;
        Array!ubyte decoded;

        if (is_pem(cert_data))
        {
            decoded = decode_pem(cert_data);
            if (decoded.length == 0)
                return InternalResult.data_error;
            der = decoded[];
        }

        cert.store = CertOpenStore(
            CERT_STORE_PROV_MEMORY,
            0, 0, 0, null
        );
        if (cert.store is null)
            return getlasterror_result();

        if (!CertAddEncodedCertificateToStore(
            cert.store,
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            der.ptr,
            cast(DWORD)der.length,
            CERT_STORE_ADD_REPLACE_EXISTING,
            cast(PCCERT_CONTEXT*)&cert.context))
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

Result load_private_key(ref KeyPair kp, const(ubyte)[] key_data)
{
    version (Windows)
    {
        if (key_data.length == 0)
            return InternalResult.invalid_parameter;

        const(ubyte)[] der = key_data;
        Array!ubyte decoded;

        if (is_pem(key_data))
        {
            decoded = decode_pem(key_data);
            if (decoded.length == 0)
                return InternalResult.data_error;
            der = decoded[];
        }

        DWORD blob_size = 0;
        // try PKCS#1 first, fall back to PKCS#8
        if (!CryptDecodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            der.ptr,
            cast(DWORD)der.length,
            0,
            null,
            null,
            &blob_size))
        {
            // Try PKCS#8 wrapper
            if (!CryptDecodeObjectEx(
                X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                PKCS_PRIVATE_KEY_INFO,
                der.ptr,
                cast(DWORD)der.length,
                0,
                null,
                null,
                &blob_size))
                return getlasterror_result();
        }

        auto blob_buf = Array!ubyte(Alloc, blob_size);
        if (!CryptDecodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            der.ptr,
            cast(DWORD)der.length,
            0,
            null,
            blob_buf.ptr,
            &blob_size))
            return getlasterror_result();

        if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, PROV_RSA_AES, CRYPT_NEWKEYSET))
        {
            if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, PROV_RSA_AES, 0))
                return getlasterror_result();
        }

        if (!CryptImportKey(kp.hprov, blob_buf.ptr, blob_size, 0, CRYPT_EXPORTABLE, &kp.hkey))
        {
            auto r = getlasterror_result();
            CryptReleaseContext(kp.hprov, 0);
            kp.hprov = 0;
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

        CRYPT_KEY_PROV_INFO key_prov_info;
        key_prov_info.pwszContainerName = null;
        key_prov_info.pwszProvName = null;
        key_prov_info.dwProvType = PROV_RSA_AES;
        key_prov_info.dwKeySpec = AT_KEYEXCHANGE;

        if (!CertSetCertificateContextProperty(
            cert.context,
            CERT_KEY_PROV_INFO_PROP_ID,
            0,
            &key_prov_info))
            return getlasterror_result();

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
        if (cert.context !is null)
            CertFreeCertificateContext(cert.context);
        if (cert.store !is null)
            CertCloseStore(cert.store, 0);
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

void* native_cert_context(ref CertRef cert)
{
    version (Windows)
        return cast(void*)cert.context;
    else
        return null;
}


Result sign_hash(ref KeyPair kp, const(ubyte)[] hash, ref Array!ubyte signature)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG sig_size = 0;
        NTSTATUS status = BCryptSignHash(kp.hcng, null,
            cast(PUCHAR)hash.ptr, cast(ULONG)hash.length,
            null, 0, &sig_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        signature = Array!ubyte(Alloc, sig_size);
        status = BCryptSignHash(kp.hcng, null,
            cast(PUCHAR)hash.ptr, cast(ULONG)hash.length,
            signature.ptr, sig_size, &sig_size, 0);
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

Result export_public_key_raw(ref KeyPair kp, ref Array!ubyte x, ref Array!ubyte y)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr,
            null, 0, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        auto blob = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr,
            blob.ptr, blob_size, &blob_size, 0);
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
    version (Windows)
    {
        if (!kp.valid)
            return Array!ubyte();

        char[256] cn_buf = void;
        if (cn.length + 3 >= cn_buf.length)
            return Array!ubyte();
        cn_buf[0 .. 3] = "CN=";
        cn_buf[3 .. 3 + cn.length] = cn[];
        cn_buf[3 + cn.length] = 0;

        ubyte[256] name_buf = void;
        DWORD name_size = name_buf.sizeof;
        if (!CertStrToNameA(X509_ASN_ENCODING, cn_buf.ptr, CERT_X500_NAME_STR, null, name_buf.ptr, &name_size, null))
            return Array!ubyte();

        CERT_NAME_BLOB subject_blob;
        subject_blob.cbData = name_size;
        subject_blob.pbData = name_buf.ptr;

        CERT_REQUEST_INFO req_info;
        req_info.dwVersion = CERT_REQUEST_V1;
        req_info.Subject = subject_blob;

        DWORD pub_info_size = 0;
        if (!CryptExportPublicKeyInfo(kp.hprov, AT_KEYEXCHANGE, X509_ASN_ENCODING, null, &pub_info_size))
            return Array!ubyte();
        auto pub_info_buf = Array!ubyte(Alloc, pub_info_size);
        if (!CryptExportPublicKeyInfo(kp.hprov, AT_KEYEXCHANGE, X509_ASN_ENCODING,
            cast(CERT_PUBLIC_KEY_INFO*)pub_info_buf.ptr, &pub_info_size))
            return Array!ubyte();
        req_info.SubjectPublicKeyInfo = *cast(CERT_PUBLIC_KEY_INFO*)pub_info_buf.ptr;

        CRYPT_ALGORITHM_IDENTIFIER sig_alg;
        sig_alg.pszObjId = cast(LPSTR)szOID_RSA_SHA256RSA.ptr;

        DWORD csr_size = 0;
        if (!CryptSignAndEncodeCertificate(kp.hprov, AT_KEYEXCHANGE,
            X509_ASN_ENCODING, X509_CERT_REQUEST_TO_BE_SIGNED,
            &req_info, &sig_alg, null, null, &csr_size))
            return Array!ubyte();

        auto csr = Array!ubyte(Alloc, csr_size);
        if (!CryptSignAndEncodeCertificate(kp.hprov, AT_KEYEXCHANGE,
            X509_ASN_ENCODING, X509_CERT_REQUEST_TO_BE_SIGNED,
            &req_info, &sig_alg, null, csr.ptr, &csr_size))
            return Array!ubyte();

        csr.resize(csr_size);
        return csr;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}


Result export_private_key(ref KeyPair kp, ref Array!ubyte der_out)
{
    version (Windows)
    {
        if (kp.hkey == 0)
            return InternalResult.invalid_parameter;

        DWORD blob_size = 0;
        if (!CryptExportKey(kp.hkey, 0, PRIVATEKEYBLOB, 0, null, &blob_size))
            return getlasterror_result();

        auto blob = Array!ubyte(Alloc, blob_size);
        if (!CryptExportKey(kp.hkey, 0, PRIVATEKEYBLOB, 0, blob.ptr, &blob_size))
            return getlasterror_result();

        // PRIVATEKEYBLOB → PKCS#1 DER
        DWORD der_size = 0;
        if (!CryptEncodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            blob.ptr,
            0,
            null,
            null,
            &der_size))
            return getlasterror_result();

        der_out = Array!ubyte(Alloc, der_size);
        if (!CryptEncodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            blob.ptr,
            0,
            null,
            der_out.ptr,
            &der_size))
        {
            auto r = getlasterror_result();
            der_out = Array!ubyte();
            return r;
        }

        der_out.resize(der_size);
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Array!ubyte encode_pem(const(ubyte)[] der, const(char)[] label)
{
    import urt.encoding : base64_encode, base64_encode_length;

    Array!ubyte result;

    // Header
    result.concat(cast(const(ubyte)[])"-----BEGIN ");
    result.concat(cast(const(ubyte)[])label);
    result.concat(cast(const(ubyte)[])"-----\n");

    // Base64 body in 64-char lines
    size_t enc_len = base64_encode_length(der.length);
    auto b64 = Array!char(Alloc, enc_len);
    base64_encode(der, b64[0 .. enc_len]);

    size_t pos = 0;
    while (pos < enc_len)
    {
        size_t line_len = enc_len - pos;
        if (line_len > 64)
            line_len = 64;
        result.concat(cast(const(ubyte)[])b64[pos .. pos + line_len]);
        result.concat(cast(const(ubyte)[])"\n");
        pos += line_len;
    }

    // Footer
    result.concat(cast(const(ubyte)[])"-----END ");
    result.concat(cast(const(ubyte)[])label);
    result.concat(cast(const(ubyte)[])"-----\n");

    return result;
}

Result export_ecdsa_private_key(ref KeyPair kp, ref Array!ubyte blob_out)
{
    version (Windows)
    {
        if (kp.hcng is null)
            return InternalResult.invalid_parameter;

        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            null, 0, &blob_size, 0);
        if (status != 0)
            return Result(cast(uint)status);

        blob_out = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            blob_out.ptr, blob_size, &blob_size, 0);
        if (status != 0)
        {
            blob_out.clear();
            return Result(cast(uint)status);
        }

        blob_out.resize(blob_size);
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

Result import_ecdsa_private_key(ref KeyPair kp, const(ubyte)[] blob_data)
{
    version (Windows)
    {
        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);

        status = BCryptImportKeyPair(kp.halg, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            &kp.hcng, cast(ubyte*)blob_data.ptr, cast(ULONG)blob_data.length, 0);
        if (status != 0)
        {
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return Result(cast(uint)status);
        }

        kp.type = KeyType.ecdsa_p256;
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}


private:

Result generate_ecdsa_p256(ref KeyPair kp)
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

        kp.type = KeyType.ecdsa_p256;
        return Result.success;
    }
    else version (Posix)
        assert(false, "TODO: mbedtls");
    else
        static assert(0, "Not implemented");
}

bool is_pem(const(ubyte)[] data)
{
    return data.length >= 11 && (cast(const(char)[])data[0 .. 11]) == "-----BEGIN ";
}

Array!ubyte decode_pem(const(ubyte)[] data)
{
    auto text = cast(const(char)[])data;

    // Find end of first line (header)
    size_t start = 0;
    while (start < text.length && text[start] != '\n')
        ++start;
    if (start < text.length)
        ++start; // skip \n

    // Find "-----END" marker
    size_t end = start;
    while (end + 5 < text.length)
    {
        if (text[end .. end + 5] == "-----")
            break;
        ++end;
    }

    if (end <= start)
        return Array!ubyte();

    // Strip whitespace and decode base64
    // First pass: count non-whitespace characters
    size_t b64_len = 0;
    for (size_t i = start; i < end; ++i)
    {
        if (text[i] != '\r' && text[i] != '\n' && text[i] != ' ')
            ++b64_len;
    }

    // Second pass: copy to contiguous buffer and decode
    auto b64_buf = Array!char(Alloc, b64_len);
    size_t j = 0;
    for (size_t i = start; i < end; ++i)
    {
        if (text[i] != '\r' && text[i] != '\n' && text[i] != ' ')
            b64_buf.ptr[j++] = text[i];
    }

    // Decode
    auto result = Array!ubyte(Alloc, base64_decode_length(b64_len));
    ptrdiff_t decoded_len = base64_decode(b64_buf[], result[]);
    if (decoded_len < 0)
        return Array!ubyte();

    result.resize(decoded_len);
    return result;
}

version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    import core.sys.windows.wincrypt;
    import core.sys.windows.windef;
    import core.sys.windows.winbase;

    pragma(lib, "Advapi32");
    pragma(lib, "Bcrypt");
    pragma(lib, "Crypt32");

    // Constants not in D runtime
    enum LPCSTR CERT_STORE_PROV_MEMORY = cast(LPCSTR)2;
    enum DWORD CERT_STORE_ADD_REPLACE_EXISTING = 3;
    enum DWORD CERT_X500_NAME_STR = 3;
    enum DWORD CERT_KEY_PROV_INFO_PROP_ID = 2;
    enum LPCSTR PKCS_RSA_PRIVATE_KEY = cast(LPCSTR)43;
    enum LPCSTR PKCS_PRIVATE_KEY_INFO = cast(LPCSTR)44;

    // Structs not in D runtime
    struct CRYPT_KEY_PROV_INFO
    {
        LPWSTR pwszContainerName;
        LPWSTR pwszProvName;
        DWORD dwProvType;
        DWORD dwFlags;
        DWORD cProvParam;
        void* rgProvParam; // CRYPT_KEY_PROV_PARAM*
        DWORD dwKeySpec;
    }

    // CSR-related structs and constants
    struct CERT_REQUEST_INFO
    {
        DWORD dwVersion;
        CERT_NAME_BLOB Subject;
        CERT_PUBLIC_KEY_INFO SubjectPublicKeyInfo;
        DWORD cAttribute;
        void* rgAttribute; // CRYPT_ATTRIBUTE*
    }

    enum CERT_REQUEST_V1 = 0;
    enum LPCSTR X509_CERT_REQUEST_TO_BE_SIGNED = cast(LPCSTR)4;
    enum szOID_RSA_SHA256RSA = "1.2.840.113549.1.1.11";

    // Functions not in D runtime
    extern (Windows) @nogc nothrow
    {
        BOOL CryptExportPublicKeyInfo(
            HCRYPTPROV hCryptProv,
            DWORD dwKeySpec,
            DWORD dwCertEncodingType,
            CERT_PUBLIC_KEY_INFO* pInfo,
            DWORD* pcbInfo
        );

        BOOL CryptSignAndEncodeCertificate(
            HCRYPTPROV hCryptProv,
            DWORD dwKeySpec,
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(void)* pvStructInfo,
            CRYPT_ALGORITHM_IDENTIFIER* pSignatureAlgorithm,
            const(void)* pvHashAuxInfo,
            BYTE* pbEncoded,
            DWORD* pcbEncoded
        );
        PCCERT_CONTEXT CertCreateSelfSignCertificate(
            HCRYPTPROV hCryptProvOrNCryptKey,
            PCERT_NAME_BLOB pSubjectIssuerBlob,
            DWORD dwFlags,
            CRYPT_KEY_PROV_INFO* pKeyProvParam,
            CRYPT_ALGORITHM_IDENTIFIER* pSignatureAlgorithm,
            SYSTEMTIME* pStartTime,
            SYSTEMTIME* pEndTime,
            void* pExtensions // PCERT_EXTENSIONS
        );

        BOOL CertStrToNameA(
            DWORD dwCertEncodingType,
            LPCSTR pszX500,
            DWORD dwStrType,
            void* pvReserved,
            BYTE* pbEncoded,
            DWORD* pcbEncoded,
            LPCSTR* ppszError
        );

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

        BOOL CryptDecodeObjectEx(
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(BYTE)* pbEncoded,
            DWORD cbEncoded,
            DWORD dwFlags,
            void* pDecodePara, // PCRYPT_DECODE_PARA
            void* pvStructInfo,
            DWORD* pcbStructInfo
        );

        BOOL CryptEncodeObjectEx(
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(void)* pvStructInfo,
            DWORD dwFlags,
            void* pEncodePara, // PCRYPT_ENCODE_PARA
            void* pvEncoded,
            DWORD* pcbEncoded
        );
    }
}
