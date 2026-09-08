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
