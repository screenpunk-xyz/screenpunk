#ifndef SCREENPUNK_NATIVE_ARCHIVE_H
#define SCREENPUNK_NATIVE_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>
/* Pure bounded bytes only. 0 success, 1 invalid bytes/integrity, 2 unsupported platform.
 * No allocation, filesystem, credentials, ownership or execution authority. */
int sp_native_archive_decode(uint16_t method, const uint8_t *input, size_t input_count,
                            uint8_t *output, size_t output_count, uint32_t expected_crc);
#endif
