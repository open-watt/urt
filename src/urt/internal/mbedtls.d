// Path-based shim that re-exports mbedtls.c's ImportC declarations.
//
// pki.d and tls.d use `import urt.internal.mbedtls` for the path-based
// name, but the ImportC of mbedtls.c is named after the file basename
// (`mbedtls`) on every D compiler. This shim bridges the two and is
// also where the pragma(lib) link directives live.
module urt.internal.mbedtls;

version (Posix)
{
    public import mbedtls;

    pragma(lib, "mbedtls");
    pragma(lib, "mbedx509");
    pragma(lib, "mbedcrypto");
}
