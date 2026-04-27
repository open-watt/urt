// C wrappers for mbedtls - sizeof() for opaque types, and wrappers for
// functions that access internal struct layouts D cannot safely replicate.

#pragma attribute(push, nothrow, nogc)

#if !defined(_WIN32)

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <mbedtls/version.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>
#include <mbedtls/pk.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/ssl.h>

size_t urt_sizeof_entropy(void)     { return sizeof(mbedtls_entropy_context); }
size_t urt_sizeof_ctr_drbg(void)    { return sizeof(mbedtls_ctr_drbg_context); }
size_t urt_sizeof_x509_crt(void)    { return sizeof(mbedtls_x509_crt); }
size_t urt_sizeof_ssl_context(void) { return sizeof(mbedtls_ssl_context); }
size_t urt_sizeof_ssl_config(void)  { return sizeof(mbedtls_ssl_config); }

// Allocator wrappers for opaque-context types whose D-side struct decls
// stop at `struct foo;` (we only ever hold a pointer). C-side malloc keeps
// the struct layout an implementation detail of mbedtls.

mbedtls_entropy_context* urt_entropy_new(void)
{
    mbedtls_entropy_context *ctx = malloc(sizeof(mbedtls_entropy_context));
    if (ctx) mbedtls_entropy_init(ctx);
    return ctx;
}
void urt_entropy_delete(mbedtls_entropy_context *ctx)
{
    if (ctx) { mbedtls_entropy_free(ctx); free(ctx); }
}

mbedtls_ctr_drbg_context* urt_ctr_drbg_new(void)
{
    mbedtls_ctr_drbg_context *ctx = malloc(sizeof(mbedtls_ctr_drbg_context));
    if (ctx) mbedtls_ctr_drbg_init(ctx);
    return ctx;
}
void urt_ctr_drbg_delete(mbedtls_ctr_drbg_context *ctx)
{
    if (ctx) { mbedtls_ctr_drbg_free(ctx); free(ctx); }
}

mbedtls_x509_crt* urt_x509_crt_new(void)
{
    mbedtls_x509_crt *crt = malloc(sizeof(mbedtls_x509_crt));
    if (crt) mbedtls_x509_crt_init(crt);
    return crt;
}
void urt_x509_crt_delete(mbedtls_x509_crt *crt)
{
    if (crt) { mbedtls_x509_crt_free(crt); free(crt); }
}

mbedtls_ssl_context* urt_ssl_new(void)
{
    mbedtls_ssl_context *ssl = malloc(sizeof(mbedtls_ssl_context));
    if (ssl) mbedtls_ssl_init(ssl);
    return ssl;
}
void urt_ssl_delete(mbedtls_ssl_context *ssl)
{
    if (ssl) { mbedtls_ssl_free(ssl); free(ssl); }
}

mbedtls_ssl_config* urt_ssl_config_new(void)
{
    mbedtls_ssl_config *conf = malloc(sizeof(mbedtls_ssl_config));
    if (conf) mbedtls_ssl_config_init(conf);
    return conf;
}
void urt_ssl_config_delete(mbedtls_ssl_config *conf)
{
    if (conf) { mbedtls_ssl_config_free(conf); free(conf); }
}

// Generate an ECDSA P-256 key into a pk context.
// Handles pk_setup + ecp_gen_key internally so D never needs to access
// mbedtls_ecp_keypair or mbedtls_ecp_group, whose layouts are version-dependent.
int urt_pk_gen_ec_p256_key(mbedtls_pk_context *pk, int (*f_rng)(void *, unsigned char *, size_t), void *p_rng)
{
    int ret = mbedtls_pk_setup(pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (ret != 0)
        return ret;
    // mbedtls_pk_ec() is deprecated in 3.1+ but present in all 2.x and 3.x versions.
    return mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(*pk), f_rng, p_rng);
}

// Export the public key as an uncompressed EC point (0x04 || X || Y).
// Returns 0 on success with *olen set to the number of bytes written.
// Uses mbedtls_pk_write_pubkey_der to avoid any direct ECP struct member access -
// the SubjectPublicKeyInfo for P-256 always ends with the 65-byte uncompressed point.
int urt_pk_export_pubkey_xy(mbedtls_pk_context *pk, unsigned char *buf, size_t buflen, size_t *olen)
{
    unsigned char der[256];
    int len = mbedtls_pk_write_pubkey_der(pk, der, sizeof(der));
    if (len < 0)
        return len;
    // SubjectPublicKeyInfo for P-256 ends with BIT STRING { 04 || X || Y } (65 bytes).
    if (len < 65 || buflen < 65)
        return MBEDTLS_ERR_ECP_BUFFER_TOO_SMALL;
    memcpy(buf, der + sizeof(der) - 65, 65);
    *olen = 65;
    return 0;
}

// Wrappers for functions whose signatures changed between mbedtls 2.x and 3.x.
// mbedtls 3.x added sig_size parameter to mbedtls_pk_sign (inserted in the middle),
// and f_rng/p_rng to mbedtls_pk_parse_key (appended at end).
// Calling from D with the wrong signature corrupts arguments on the stack.

// Always signs with SHA-256. The md_type_t enum values changed between
// mbedtls 2.x and 3.x, so we resolve the correct value here in C.
int urt_pk_sign(mbedtls_pk_context *ctx, const unsigned char *hash, size_t hash_len, unsigned char *sig, size_t sig_size, size_t *sig_len, int (*f_rng)(void *, unsigned char *, size_t), void *p_rng)
{
#if MBEDTLS_VERSION_MAJOR >= 3
    return mbedtls_pk_sign(ctx, MBEDTLS_MD_SHA256, hash, hash_len, sig, sig_size, sig_len, f_rng, p_rng);
#else
    (void)sig_size;
    return mbedtls_pk_sign(ctx, MBEDTLS_MD_SHA256, hash, hash_len, sig, sig_len, f_rng, p_rng);
#endif
}

// Import raw EC P-256 key components (d, X, Y) into a pk context.
// Sets up the pk context, group, private key, and public key point.
int urt_pk_import_ec_p256_key(mbedtls_pk_context *pk, const unsigned char *d, size_t d_len, const unsigned char *xy, size_t xy_len)
{
    int ret = mbedtls_pk_setup(pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (ret != 0)
        return ret;

    mbedtls_ecp_keypair *ec = mbedtls_pk_ec(*pk);

#if MBEDTLS_VERSION_MAJOR >= 3
    ret = mbedtls_ecp_group_load(&ec->private_grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) return ret;
    ret = mbedtls_mpi_read_binary(&ec->private_d, d, d_len);
    if (ret != 0) return ret;
    // xy is 0x04 || X || Y (65 bytes)
    ret = mbedtls_ecp_point_read_binary(&ec->private_grp, &ec->private_Q, xy, xy_len);
#else
    ret = mbedtls_ecp_group_load(&ec->grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) return ret;
    ret = mbedtls_mpi_read_binary(&ec->d, d, d_len);
    if (ret != 0) return ret;
    ret = mbedtls_ecp_point_read_binary(&ec->grp, &ec->Q, xy, xy_len);
#endif
    return ret;
}

// Export the raw private key scalar d (32 bytes for P-256).
// Accesses version-dependent struct member (d vs private_d).
int urt_pk_export_privkey_d(mbedtls_pk_context *pk, unsigned char *buf, size_t buflen, size_t *olen)
{
    mbedtls_ecp_keypair *ec = mbedtls_pk_ec(*pk);
#if MBEDTLS_VERSION_MAJOR >= 3
    mbedtls_mpi *d = &ec->private_d;
#else
    mbedtls_mpi *d = &ec->d;
#endif
    size_t len = mbedtls_mpi_size(d);
    if (buflen < len)
        return MBEDTLS_ERR_ECP_BUFFER_TOO_SMALL;
    *olen = len;
    return mbedtls_mpi_write_binary(d, buf, len);
}

#endif
