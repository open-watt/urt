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

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
