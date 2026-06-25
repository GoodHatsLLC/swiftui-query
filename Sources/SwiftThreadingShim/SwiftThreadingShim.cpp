#if defined(__linux__)
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

// The Observation runtime expects `swift::threading::fatal` to be available.
// Swift 6.2 toolchains for Linux may omit the SwiftThreading library, so we
// provide a minimal shim that terminates the process with a message. This keeps
// tests linkable on Linux while maintaining parity with the runtime contract.
namespace swift {
namespace threading {
void fatal(const char *message, ...) {
    std::fprintf(stderr, "SwiftThreading fatal: ");

    va_list args;
    va_start(args, message);
    std::vfprintf(stderr, message, args);
    va_end(args);

    std::fprintf(stderr, "\n");
    std::abort();
}
} // namespace threading
} // namespace swift
#endif
