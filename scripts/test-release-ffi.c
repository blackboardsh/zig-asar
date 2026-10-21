#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct AsarArchive AsarArchive;
extern AsarArchive *asar_open(const char *path);
extern void asar_close(AsarArchive *archive);
extern const uint8_t *asar_read_file(AsarArchive *archive, const char *path,
                                     size_t *size);
extern void asar_free_buffer(const uint8_t *buffer, size_t size);
extern int asar_pack(const char *source, const char *output,
                     const char **patterns, int pattern_count);

static void verify_archive(const char *path) {
    static const uint8_t expected[] = {0, 1, 2, 127, 128, 254, 255};
    AsarArchive *archive = asar_open(path);
    assert(archive != NULL);
    size_t size = 0;
    const uint8_t *data = asar_read_file(archive, "nested/payload.bin", &size);
    assert(data != NULL);
    assert(size == sizeof(expected));
    assert(memcmp(data, expected, size) == 0);
    asar_free_buffer(data, size);
    asar_close(archive);
}

int main(int argc, char **argv) {
    assert(argc == 4);
    verify_archive(argv[2]);
    const char *patterns[] = {"*.node"};
    assert(asar_pack(argv[1], argv[3], patterns, 1) == 1);
    verify_archive(argv[3]);
    puts("Validated Apple-ld linkage and all five ASAR C ABI functions");
    return 0;
}
