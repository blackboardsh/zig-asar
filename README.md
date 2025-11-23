# zig-asar

A fast, lightweight ASAR (Electron Archive) implementation in Zig.

## Features

- **Fast**: Reads files on-demand without loading entire archive
- **Small**: ~500 lines of Zig, minimal dependencies
- **Cross-platform**: Works on macOS, Windows, Linux
- **Dual API**: C FFI for native code + CLI tool
- **Uncompressed**: Archives are uncompressed for fast access (compression handled by bundler)

## Building

```bash
zig build
```

This produces:
- `zig-out/lib/libasar.{dylib,dll,so}` - Dynamic library
- `zig-out/bin/zig-asar` - CLI tool

## CLI Usage

```bash
# Pack a directory
zig-asar pack myapp app.asar

# With unpacked files (native modules, executables)
zig-asar pack myapp app.asar --unpack *.node --unpack *.dll --unpack bin/**

# List files
zig-asar list app.asar

# Extract a file
zig-asar extract app.asar views/index.html
```

## C API

```c
#include <stddef.h>
#include <stdint.h>

typedef struct AsarArchive AsarArchive;

// Reading
AsarArchive* asar_open(const char* path);
const uint8_t* asar_read_file(AsarArchive* archive, const char* path, size_t* size_out);
void asar_free_buffer(const uint8_t* buffer, size_t size);
void asar_close(AsarArchive* archive);

// Writing
int asar_pack(const char* source_path, const char* output_path,
              const char** unpack_patterns, int pattern_count);
```

## Bun FFI Usage

```typescript
import { dlopen, FFI, ptr, CString } from "bun:ffi";

const lib = dlopen("zig-out/lib/libasar.dylib", {
  asar_pack: {
    args: [FFI.cstring, FFI.cstring, FFI.ptr, FFI.int],
    returns: FFI.int,
  },
});

// Pack a directory
const result = lib.symbols.asar_pack(
  ptr(Buffer.from("/path/to/source\0")),
  ptr(Buffer.from("/path/to/output.asar\0")),
  null,
  0
);
```

## ASAR Format

```
[8 bytes: header size as u64 little-endian]
[N bytes: JSON header UTF-8]
[padding to 4-byte alignment]
[file data concatenated]
```

Header JSON structure:
```json
{
  "files": {
    "file.txt": {
      "size": 1234,
      "offset": "0"
    },
    "subdir": {
      "files": {
        "nested.txt": {
          "size": 567,
          "offset": "1234"
        }
      }
    }
  }
}
```

Unpacked files are stored in `{archive}.asar.unpacked/` with the same directory structure.

## Testing

```bash
zig build test
```

## License

MIT
