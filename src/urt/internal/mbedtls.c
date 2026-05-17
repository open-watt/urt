// C wrappers for mbedtls - sizeof() for opaque types, and wrappers for
// functions that access internal struct layouts D cannot safely replicate.

#if !defined(_WIN32)

#include <stddef.h>
#include <string.h>
#include <mbedtls/version.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>
#include <mbedtls/pk.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/ssl.h>
#include <mbedtls/gcm.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>

size_t urt_sizeof_entropy(void)     { return sizeof(mbedtls_entropy_context); }
size_t urt_sizeof_ctr_drbg(void)    { return sizeof(mbedtls_ctr_drbg_context); }
size_t urt_sizeof_x509_crt(void)    { return sizeof(mbedtls_x509_crt); }
size_t urt_sizeof_ssl_context(void) { return sizeof(mbedtls_ssl_context); }
size_t urt_sizeof_ssl_config(void)  { return sizeof(mbedtls_ssl_config); }

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

// AES-GCM one-shot encrypt. Caller-allocated output buffers.
// key_len: 16/24/32 for AES-128/192/256. tag_len: 4..16.
int urt_gcm_encrypt(const unsigned char *key, size_t key_len,
                    const unsigned char *iv, size_t iv_len,
                    const unsigned char *aad, size_t aad_len,
                    const unsigned char *plaintext, size_t pt_len,
                    unsigned char *ciphertext,
                    unsigned char *tag, size_t tag_len)
{
    mbedtls_gcm_context ctx;
    mbedtls_gcm_init(&ctx);
    int ret = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, pt_len, iv, iv_len,
                                        aad, aad_len, plaintext, ciphertext, tag_len, tag);
    mbedtls_gcm_free(&ctx);
    return ret;
}

// ECDH P-256 raw shared-secret computation.
// priv_d: 32-byte big-endian private scalar.
// peer_xy: 64-byte uncompressed peer point (X || Y, no 0x04 prefix).
// shared_x_out: 32 bytes — big-endian X coordinate of (priv_d * peer_point).
int urt_ecdh_p256_compute_shared(const unsigned char *priv_d, size_t priv_len,
                                  const unsigned char *peer_xy, size_t peer_xy_len,
                                  int (*f_rng)(void *, unsigned char *, size_t), void *p_rng,
                                  unsigned char *shared_x_out)
{
    if (priv_len != 32 || peer_xy_len != 64)
        return MBEDTLS_ERR_ECP_BAD_INPUT_DATA;

    int ret;
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret == 0)
        ret = mbedtls_mpi_read_binary(&d, priv_d, priv_len);
    if (ret == 0)
    {
        unsigned char point[65];
        point[0] = 0x04;
        memcpy(point + 1, peer_xy, 64);
        ret = mbedtls_ecp_point_read_binary(&grp, &Q, point, sizeof(point));
    }
    if (ret == 0)
        ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, f_rng, p_rng);
    if (ret == 0)
        ret = mbedtls_mpi_write_binary(&z, shared_x_out, 32);

    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

// AES-GCM one-shot decrypt + tag verify.
// Returns MBEDTLS_ERR_GCM_AUTH_FAILED if the tag is wrong.
int urt_gcm_decrypt(const unsigned char *key, size_t key_len,
                    const unsigned char *iv, size_t iv_len,
                    const unsigned char *aad, size_t aad_len,
                    const unsigned char *ciphertext, size_t ct_len,
                    const unsigned char *tag, size_t tag_len,
                    unsigned char *plaintext)
{
    mbedtls_gcm_context ctx;
    mbedtls_gcm_init(&ctx);
    int ret = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_gcm_auth_decrypt(&ctx, ct_len, iv, iv_len, aad, aad_len,
                                       tag, tag_len, ciphertext, plaintext);
    mbedtls_gcm_free(&ctx);
    return ret;
}

#endif
