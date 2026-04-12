// minimal D bindings for mbedtls — only what pki.d and tls.d need
module urt.internal.mbedtls;

version (Posix):

pragma(lib, "mbedtls");
pragma(lib, "mbedx509");
pragma(lib, "mbedcrypto");

nothrow @nogc:
extern(C):

// --- PK (public key abstraction) ---

struct mbedtls_pk_info_t; // opaque

struct mbedtls_pk_context
{
    const(mbedtls_pk_info_t)* pk_info;
    void* pk_ctx;
}

// mbedtls_pk_type_t and mbedtls_md_type_t enum values changed between 2.x
// and 3.x, so D must not hardcode them. All operations that need these enums
// (pk_setup, pk_sign, etc.) are wrapped in urt/internal/mbedtls.c where the
// correct header values are resolved at compile time.

void mbedtls_pk_init(mbedtls_pk_context* ctx);
void mbedtls_pk_free(mbedtls_pk_context* ctx);

// --- wrappers from urt/internal/mbedtls.c ---
// These handle operations whose signatures changed between mbedtls 2.x and 3.x,
// as well as operations that access internal struct layouts.

int urt_pk_gen_ec_p256_key(mbedtls_pk_context* pk, int function(void*, ubyte*, size_t) nothrow @nogc f_rng, void* p_rng);
int urt_pk_export_pubkey_xy(mbedtls_pk_context* pk, ubyte* buf, size_t buflen, size_t* olen);
int urt_pk_sign(mbedtls_pk_context* ctx, const(ubyte)* hash, size_t hash_len, ubyte* sig, size_t sig_size, size_t* sig_len, int function(void*, ubyte*, size_t) nothrow @nogc f_rng, void* p_rng);
int urt_pk_import_ec_p256_key(mbedtls_pk_context* pk, const(ubyte)* d, size_t d_len, const(ubyte)* xy, size_t xy_len);
int urt_pk_export_privkey_d(mbedtls_pk_context* pk, ubyte* buf, size_t buflen, size_t* olen);


// --- X.509 certificate ---

// mbedtls_x509_crt is complex (~200+ bytes). We only use it through pointers
// allocated via urt/internal/mbedtls.c (urt_mbedtls_x509_crt_new/delete).
struct mbedtls_x509_crt;

void mbedtls_x509_crt_init(mbedtls_x509_crt* crt);
void mbedtls_x509_crt_free(mbedtls_x509_crt* crt);
int mbedtls_x509_crt_parse_der(mbedtls_x509_crt* chain, const(ubyte)* buf, size_t buflen);
int mbedtls_x509_crt_parse(mbedtls_x509_crt* chain, const(ubyte)* buf, size_t buflen);


// --- Entropy & CTR-DRBG (random number generation) ---

// These are large structs. Allocated via urt/internal/mbedtls.c (urt_mbedtls_entropy_new/delete, urt_mbedtls_ctr_drbg_new/delete).
struct mbedtls_entropy_context;
struct mbedtls_ctr_drbg_context;

void mbedtls_entropy_init(mbedtls_entropy_context* ctx);
void mbedtls_entropy_free(mbedtls_entropy_context* ctx);
int mbedtls_entropy_func(void* data, ubyte* output, size_t len);

void mbedtls_ctr_drbg_init(mbedtls_ctr_drbg_context* ctx);
void mbedtls_ctr_drbg_free(mbedtls_ctr_drbg_context* ctx);
int mbedtls_ctr_drbg_seed(mbedtls_ctr_drbg_context* ctx, int function(void*, ubyte*, size_t) nothrow @nogc f_entropy, void* p_entropy, const(ubyte)* custom, size_t len);
int mbedtls_ctr_drbg_random(void* p_rng, ubyte* output, size_t output_len);


// --- SSL/TLS ---

struct mbedtls_ssl_context;
struct mbedtls_ssl_config;

enum MBEDTLS_SSL_IS_CLIENT = 0;
enum MBEDTLS_SSL_IS_SERVER = 1;
enum MBEDTLS_SSL_TRANSPORT_STREAM = 0;
enum MBEDTLS_SSL_PRESET_DEFAULT = 0;

enum MBEDTLS_ERR_SSL_WANT_READ = -0x6900;
enum MBEDTLS_ERR_SSL_WANT_WRITE = -0x6880;
enum MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY = -0x7880;

void mbedtls_ssl_init(mbedtls_ssl_context* ssl);
void mbedtls_ssl_free(mbedtls_ssl_context* ssl);
int mbedtls_ssl_setup(mbedtls_ssl_context* ssl, const(mbedtls_ssl_config)* conf);
void mbedtls_ssl_set_bio(mbedtls_ssl_context* ssl, void* p_bio, int function(void*, const(ubyte)*, size_t) nothrow @nogc f_send, int function(void*, ubyte*, size_t) nothrow @nogc f_recv, void* f_recv_timeout);
int mbedtls_ssl_handshake(mbedtls_ssl_context* ssl);
int mbedtls_ssl_read(mbedtls_ssl_context* ssl, ubyte* buf, size_t len);
int mbedtls_ssl_write(mbedtls_ssl_context* ssl, const(ubyte)* buf, size_t len);
int mbedtls_ssl_close_notify(mbedtls_ssl_context* ssl);
int mbedtls_ssl_set_hostname(mbedtls_ssl_context* ssl, const(char)* hostname);

void mbedtls_ssl_config_init(mbedtls_ssl_config* conf);
void mbedtls_ssl_config_free(mbedtls_ssl_config* conf);
int mbedtls_ssl_config_defaults(mbedtls_ssl_config* conf, int endpoint, int transport, int preset);
void mbedtls_ssl_conf_rng(mbedtls_ssl_config* conf, int function(void*, ubyte*, size_t) nothrow @nogc f_rng, void* p_rng);
void mbedtls_ssl_conf_ca_chain(mbedtls_ssl_config* conf, mbedtls_x509_crt* ca_chain, void* ca_crl);
int mbedtls_ssl_conf_own_cert(mbedtls_ssl_config* conf, mbedtls_x509_crt* own_cert, mbedtls_pk_context* pk_key);
void mbedtls_ssl_conf_authmode(mbedtls_ssl_config* conf, int authmode);

alias mbedtls_ssl_conf_sni_cb = int function(void* p_info, mbedtls_ssl_context* ssl, const(ubyte)* name, size_t name_len) nothrow @nogc;
void mbedtls_ssl_conf_sni(mbedtls_ssl_config* conf, mbedtls_ssl_conf_sni_cb f_sni, void* p_sni);

enum MBEDTLS_SSL_VERIFY_NONE = 0;
enum MBEDTLS_SSL_VERIFY_OPTIONAL = 1;
enum MBEDTLS_SSL_VERIFY_REQUIRED = 2;


// --- sizeof() from urt/internal/mbedtls.c (opaque types too complex to replicate) ---

size_t urt_sizeof_entropy();
size_t urt_sizeof_ctr_drbg();
size_t urt_sizeof_x509_crt();
size_t urt_sizeof_ssl_context();
size_t urt_sizeof_ssl_config();

import urt.mem.alloc;

mbedtls_entropy_context* urt_entropy_new()
{
    auto ctx = cast(mbedtls_entropy_context*)alloc(urt_sizeof_entropy()).ptr;
    if (ctx)
        mbedtls_entropy_init(ctx);
    return ctx;
}

void urt_entropy_delete(mbedtls_entropy_context* ctx)
{
    if (ctx)
    {
        mbedtls_entropy_free(ctx);
        free((cast(void*)ctx)[0..urt_sizeof_entropy()]);
    }
}

mbedtls_ctr_drbg_context* urt_ctr_drbg_new()
{
    auto ctx = cast(mbedtls_ctr_drbg_context*)alloc(urt_sizeof_ctr_drbg()).ptr;
    if (ctx)
        mbedtls_ctr_drbg_init(ctx);
    return ctx;
}

void urt_ctr_drbg_delete(mbedtls_ctr_drbg_context* ctx)
{
    if (ctx)
    {
        mbedtls_ctr_drbg_free(ctx);
        free((cast(void*)ctx)[0..urt_sizeof_ctr_drbg()]);
    }
}

mbedtls_x509_crt* urt_x509_crt_new()
{
    auto ctx = cast(mbedtls_x509_crt*)alloc(urt_sizeof_x509_crt()).ptr;
    if (ctx)
        mbedtls_x509_crt_init(ctx);
    return ctx;
}

void urt_x509_crt_delete(mbedtls_x509_crt* crt)
{
    if (crt)
    {
        mbedtls_x509_crt_free(crt);
        free((cast(void*)crt)[0..urt_sizeof_x509_crt()]);
    }
}

mbedtls_ssl_context* urt_ssl_new()
{
    auto ctx = cast(mbedtls_ssl_context*)alloc(urt_sizeof_ssl_context()).ptr;
    if (ctx)
        mbedtls_ssl_init(ctx);
    return ctx;
}

void urt_ssl_delete(mbedtls_ssl_context* ssl)
{
    if (ssl)
    {
        mbedtls_ssl_free(ssl);
        free((cast(void*)ssl)[0..urt_sizeof_ssl_context()]);
    }
}

mbedtls_ssl_config* urt_ssl_config_new()
{
    auto ctx = cast(mbedtls_ssl_config*)alloc(urt_sizeof_ssl_config()).ptr;
    if (ctx)
        mbedtls_ssl_config_init(ctx);
    return ctx;
}

void urt_ssl_config_delete(mbedtls_ssl_config* conf)
{
    if (conf)
    {
        mbedtls_ssl_config_free(conf);
        free((cast(void*)conf)[0..urt_sizeof_ssl_config()]);
    }
}
