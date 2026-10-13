# μRT (urt)

μRT (microRuntime) is a small and lightweight runtime library for the D programming language, designed for realtime and embedded systems. It is an alternative to the standard D runtime (druntime) and Phobos standard library, with a focus on minimalism, performance, and predictability.

## Features

*   **No Garbage Collection:** `urt` is designed to work without a garbage collector, making it suitable for systems with strict memory constraints.
*   **Lightweight:** The library is small and has minimal dependencies, reducing the overall footprint of your application.
*   **Real-time Capable:** `urt` is designed with real-time systems in mind, providing predictable performance and low latency.

## Getting Started

To use `urt` in your D project, simply add it as a dependency in your `dub.json` file:

```json
{
  "dependencies": {
    "urt": "~>0.1.0"
  }
}
```

## Durations

`Duration` prints signed, nonzero unit terms from weeks down to seconds. Seconds
carry a decimal fraction (`1min10.01s`); a duration below one second uses the largest
of `ms`, `us` or `ns` with a magnitude of at least one (`350ms`, `10.25us`). Zero is
`0s`. The empty format spec retains full nanosecond precision and spells minutes
`min`, so its output round-trips through `Duration.fromString`.

The compact spec is `tN[.P]`, with single digits `N=1..9` and `P=0..9`:

- `t2` keeps at most two nonzero unit terms: `1h2min3s` becomes `1h2m`, and `1h3s`
  remains `1h3s`. Omitted terms are truncated towards zero.
- `t2.1` additionally limits the fractional tail to one decimal place. Fractions
  round to nearest, with ties away from zero; trailing zeros are omitted and
  carries normalize the units before applying the term limit. For example,
  `59.999s` becomes `1m`.
- A decimal fraction belongs to its unit term: `10.01s` is one term. `P` counts
  fractional places in the displayed unit, not significant digits.

Every explicit compact spec abbreviates minutes to `m`. Compact output is for
display and cannot be relied on to round-trip; the parser accepts only `min`,
including in compounds (`3h10min5s`). Bare `m` denotes metres in untyped quantities.

Use `tformat("{0,t2.1}", duration)` or `Format(duration, "t2.1")`. Parsing accepts
one leading sign and ordered unit terms; the final term may have a decimal
fraction of up to nine digits. Arithmetic stays integer, with overflow rejected
before changing the value. Nanoseconds finer than the platform tick are subject
to its existing tick conversion. `parse_uint` supplies the numeric parts and
reports overflow with zero bytes consumed.

Fractional arithmetic and unit decomposition use 32-bit values after splitting
the whole seconds. Parsing and formatting share the existing decimal-power table.

## Class casts

Class identity conversions and upcasts use the static source and target types.
Downcasts require a `Source.dyn_cast!Target(source)` contract; there is no fallback
to compiler `TypeInfo`. The contract must return a value convertible to the
target type, preserve qualifiers, and be `nothrow @nogc`. An incompatible object
returns null. Null inputs bypass the contract at runtime, but still require a
valid contract at compile time.

A hierarchy can expose its existing checked cast function with an inherited
alias on its root class:

```d
alias dyn_cast = application.types.checked_cast;
```

The function takes the source reference explicitly, so application metadata and
ancestry checks stay in the application. The contract must not implement itself
with the same D downcast, which would recurse.

`Throwable` supplies no downcast contract. All Makefile targets default to
`NOEXCEPTIONS=1`; LDC also uses `--fno-exceptions`. Compiler-generated throw
entry points terminate, and Windows retains stack-trace capture and symbol
resolution. Setting `NOEXCEPTIONS=0` includes the unsupported legacy exception
runtime and fails at its `Throwable`-to-`Error` cast.

Class-to-interface dynamic casts remain unsupported by this class-cast contract.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
