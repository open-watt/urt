/*
 * OpenWatt mbedtls 2.28.1 config for Bouffalo BL808 (D0 + M0) and BL618.
 *
 * Built against: mbedtls 2.28.1 (upstream tag, see third_party/mbedtls_bl808/
 * upstream/mbedtls-2.28.1.tar.gz). The 24 headers in this directory are the
 * gcc-computed transitive closure of urt/internal/mbedtls.c's includes under
 * this config; libmbedtls.a in platforms/{bl808,bl618}/lib/ is the prebuilt
 * library matched to this header set. When bumping mbedtls, rebuild the .a
 * and re-run the closure computation to keep the two in sync.
 *
 * Scope: TLS 1.2 + 1.3 (client+server), X.509 validation, RSA + ECDSA P-256/P-384,
 * ECDH P-256/Curve25519, AES (all modes), ChaCha20-Poly1305, SHA-1/256/384/512,
 * HMAC + HKDF + PBKDF2, CTR-DRBG. Sized to cover today's TLS/Tesla-BLE consumers
 * plus the listed future ones (SSH, WPA supplicant, Zigbee/Thread association)
 * without re-rolling the .a.
 *
 * Trimmed off: DTLS, deprecated ciphers (ARC4/3DES/DES/Blowfish/Camellia/ARIA/
 * XTEA), MD2/MD4/MD5-as-primary, RIPEMD-160, debug/test machinery.
 *
 * Build-time platform extension hooks (xSemaphore/pvPortMalloc/etc.) are
 * declared in shim/include/ and resolved at link-time by OpenWatt.
 */
#ifndef MBEDTLS_CONFIG_OPENWATT_H
#define MBEDTLS_CONFIG_OPENWATT_H

/* ---------------- Platform ---------------- */
#define MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_MEMORY
/* Note: NOT setting MBEDTLS_PLATFORM_NO_STD_FUNCTIONS - lets mbedtls call
 * snprintf/printf via the integrator's libc/shim. OpenWatt link-time
 * supplies a minimal snprintf (X.509 / OID / error formatting only). */
#define MBEDTLS_NO_PLATFORM_ENTROPY
#define MBEDTLS_HAVE_ASM
#define MBEDTLS_HAVE_TIME

/* Threading: vendor port uses bl_sec_*_mutex_take/give around SEC engine.
 * No mbedtls-level threading wrapper needed - we serialise at the HW seam. */

/* ---------------- Symmetric ciphers ---------------- */
#define MBEDTLS_AES_C
#define MBEDTLS_AES_ROM_TABLES
#define MBEDTLS_CIPHER_C
#define MBEDTLS_CIPHER_MODE_CBC
#define MBEDTLS_CIPHER_MODE_CFB
#define MBEDTLS_CIPHER_MODE_CTR
#define MBEDTLS_CIPHER_MODE_OFB
#define MBEDTLS_CIPHER_MODE_XTS
#define MBEDTLS_CIPHER_PADDING_PKCS7
#define MBEDTLS_CIPHER_PADDING_ZEROS
#define MBEDTLS_CCM_C
#define MBEDTLS_GCM_C
#define MBEDTLS_CMAC_C
#define MBEDTLS_NIST_KW_C
#define MBEDTLS_CHACHA20_C
#define MBEDTLS_CHACHAPOLY_C
#define MBEDTLS_POLY1305_C

/* Strip legacy/deprecated symmetric primitives */
#define MBEDTLS_REMOVE_ARC4_CIPHERSUITES
#define MBEDTLS_REMOVE_3DES_CIPHERSUITES

/* ---------------- Hashes ---------------- */
#define MBEDTLS_MD_C
#define MBEDTLS_SHA1_C          /* WPA PRF, TLS legacy cipher suites, X.509 legacy */
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA512_C        /* covers SHA-384 also */
#define MBEDTLS_MD5_C           /* TLS 1.2 PRF, PEM PBE - not as primary hash */
#define MBEDTLS_HKDF_C
#define MBEDTLS_PKCS5_C         /* PBKDF2 (WPA-PSK, PEM password) */

/* ---------------- Public key ---------------- */
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_PK_WRITE_C
#define MBEDTLS_RSA_C
#define MBEDTLS_PKCS1_V15
#define MBEDTLS_PKCS1_V21
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_OID_C
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_BASE64_C

/* ECC */
#define MBEDTLS_ECP_C
#define MBEDTLS_ECP_NIST_OPTIM
#define MBEDTLS_ECDH_C
#define MBEDTLS_ECDSA_C
#define MBEDTLS_ECDSA_DETERMINISTIC
#define MBEDTLS_ECJPAKE_C       /* Thread commissioning */

/* Curves enabled */
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED    /* TLS, Tesla BLE, modern X.509 */
#define MBEDTLS_ECP_DP_SECP384R1_ENABLED    /* TLS, X.509 CA chains */
#define MBEDTLS_ECP_DP_CURVE25519_ENABLED   /* SSH, modern TLS 1.3, WireGuard-ish */

/* ---------------- X.509 ---------------- */
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_X509_CRL_PARSE_C
#define MBEDTLS_X509_CSR_PARSE_C
#define MBEDTLS_X509_CREATE_C
#define MBEDTLS_X509_CRT_WRITE_C
#define MBEDTLS_X509_CSR_WRITE_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_PEM_WRITE_C

/* ---------------- RNG ---------------- */
#define MBEDTLS_CTR_DRBG_C
#define MBEDTLS_HMAC_DRBG_C
#define MBEDTLS_ENTROPY_C
/* Entropy source: register at runtime via mbedtls_entropy_add_source() from
 * OpenWatt init code. Our HW TRNG is accessed via D-side driver, not via
 * the MBEDTLS_ENTROPY_HARDWARE_ALT hook (which would force a hard external
 * symbol). Runtime registration is the standard mbedtls idiom and keeps
 * the .a self-contained. */

/* ---------------- SSL/TLS ---------------- */
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_SRV_C
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_PROTO_TLS1_3        /* 2.28 has experimental 1.3 support */
#define MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
#define MBEDTLS_SSL_ALPN
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_SSL_MAX_FRAGMENT_LENGTH
#define MBEDTLS_SSL_ENCRYPT_THEN_MAC
#define MBEDTLS_SSL_EXTENDED_MASTER_SECRET
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE
#define MBEDTLS_SSL_RENEGOTIATION
#define MBEDTLS_SSL_SESSION_TICKETS
#define MBEDTLS_SSL_TICKET_C
#define MBEDTLS_SSL_CACHE_C
#define MBEDTLS_SSL_COOKIE_C
#define MBEDTLS_SSL_CONTEXT_SERIALIZATION

/* TLS key-exchange modes - enable all we plausibly need */
#define MBEDTLS_KEY_EXCHANGE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_DHE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDH_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDH_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_PSK_ENABLED            /* WPA-PSK style, EAP-PSK */
#define MBEDTLS_KEY_EXCHANGE_DHE_PSK_ENABLED
#define MBEDTLS_KEY_EXCHANGE_RSA_PSK_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_PSK_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECJPAKE_ENABLED        /* Thread */

#define MBEDTLS_DHM_C

/* ---------------- HW accel: weak-symbol overrides ---------------------
 *
 * We do NOT define MBEDTLS_*_ALT here. mbedtls compiles its own software
 * implementations into the .a as normal. After build, the Makefile runs
 * objcopy --weaken-symbol on the per-block primitives below, marking
 * them weak in the archive.
 *
 * Effect at link time:
 *   - With no HW shim: weak SW symbols selected. .a is self-contained.
 *   - With HW shim:    strong HW symbols in OpenWatt override the weak
 *                      SW ones. No .a rebuild needed.
 *
 * Functions weakened (see Makefile):
 *   mbedtls_internal_aes_encrypt/_decrypt
 *   mbedtls_aes_setkey_enc/_dec
 *   mbedtls_internal_sha1_process / _sha256_process
 *
 * Entropy: NOT using MBEDTLS_ENTROPY_HARDWARE_ALT (would force a hard
 * external symbol). Register our HW TRNG via mbedtls_entropy_add_source()
 * at runtime from OpenWatt init.
 *
 * Bignum (RSA/ECDH/ECDSA) acceleration: deferred. mbedtls 2.28 has no
 * fine-grained bignum hooks, and coarse MBEDTLS_BIGNUM_ALT would inflate
 * the mpi context surface. Asymmetric ops stay software. Revisit if
 * handshake latency becomes a problem in measurement.
 */

/* ---------------- Hardening / size ---------------- */
#define MBEDTLS_AES_FEWER_TABLES       /* save ~6KB rodata */
#define MBEDTLS_ECP_WINDOW_SIZE 4      /* small RAM footprint */
#define MBEDTLS_ECP_FIXED_POINT_OPTIM 0

/* No debug/test glue in the .a */
/* #define MBEDTLS_SELF_TEST */
/* #define MBEDTLS_DEBUG_C */

/* The standard sanity-check header. Must be last. */
#include "mbedtls/check_config.h"

#endif /* MBEDTLS_CONFIG_OPENWATT_H */
