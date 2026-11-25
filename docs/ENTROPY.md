# Checked random bytes

Use crypto_random_bytes for keys, nonces, salts and unpredictable protocol discriminators. Check its Result. Failed requests zero the destination; those bytes are not random output. Unsupported targets return an error. urt.rand is non-cryptographic PCG.

On ESP, requests succeed only while an RF entropy source is active. The shim holds the PHY lifecycle lock across the check and read. Before RF startup, while the PHY is asleep, on RF-less targets, or in SDK bring-up bypass mode, requests fail. uRT does not enable the shared bootloader/SAR ADC source behind its owner's back. Retry after radio readiness or fail the operation; timer/address seeds are not an alternative.

BL618 and BL808 M0 use SEC_ENG directly, including NoTLS. The output block is passed by reference; access/health failures return an error. M0 initializes the TRNG once before launching D0; an initialization or seed-read failure leaves D0 halted and reports through the early UART.

BL808 D0 never accesses SEC_ENG. M0 hands over 64 strong bytes in an aligned, reserved IPC slot before releasing D0. The existing SHA-512 entropy accumulator requires 64 bytes; the CTR-DRBG's security strength remains 256 bits. D0 consumes and zeroes the slot once, and both crypto_random_bytes and TLS use its existing per-image MbedTLS CTR-DRBG. Disabling that backend makes D0 random bytes unsupported rather than enabling a weak fallback.

D0 has no periodic reseed. Its pinned MbedTLS 2.28.1 uses signed int counters, so the largest safe interval is INT_MAX - 1: 2,147,483,646 Generate calls, below [SP 800-90A's](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-90Ar1.pdf) 2^48 AES CTR-DRBG limit. The next request returns a checked entropy error; it never reuses the boot seed. State compromise loses prediction resistance until a fresh M0 boot seed, a PM-accepted policy for this device class subject to owner review. There is no IPC refill or PCG fallback.

Windows uses BCrypt without MbedTLS. POSIX NoTLS uses OS getentropy in bounded chunks, retrying interrupted calls. Other existing hardware and MbedTLS providers propagate errors. No provider substitutes general PRNG output.

crypto_random_override is unittest-only failure injection; restore it after a test. It adds no release state.
