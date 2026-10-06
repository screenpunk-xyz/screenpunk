#include "CNativeArchive.h"
#if defined(__APPLE__)
#include <zlib.h>
#include <string.h>
#include <limits.h>
int sp_native_archive_decode(uint16_t method, const uint8_t *input, size_t input_count,
                            uint8_t *output, size_t output_count, uint32_t expected_crc) {
    if (!input || !output || !input_count || !output_count ||
        input_count > 25u * 1024u * 1024u || output_count > 50u * 1024u * 1024u ||
        input_count > UINT_MAX || output_count > UINT_MAX) return 1;
    if (method == 0) {
        if (input_count != output_count) return 1;
        memcpy(output, input, output_count);
    } else if (method == 8) {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        stream.next_in = (Bytef *)input;
        stream.avail_in = (uInt)input_count;
        stream.next_out = output;
        stream.avail_out = (uInt)output_count;
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 1;
        int status = inflate(&stream, Z_FINISH);
        int valid = status == Z_STREAM_END && stream.total_in == input_count &&
                    stream.total_out == output_count && stream.avail_in == 0;
        int ended = inflateEnd(&stream);
        if (!valid || ended != Z_OK) return 1;
    } else return 1;
    uLong checksum = crc32(0L, Z_NULL, 0);
    checksum = crc32(checksum, output, (uInt)output_count);
    return (uint32_t)checksum == expected_crc ? 0 : 1;
}
#else
int sp_native_archive_decode(uint16_t method, const uint8_t *input, size_t input_count,
                            uint8_t *output, size_t output_count, uint32_t expected_crc) {
    (void)method; (void)input; (void)input_count;
    (void)output; (void)output_count; (void)expected_crc;
    return 2;
}
#endif
