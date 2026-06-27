/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file simble_framing.c
 * @brief The 4-byte big-endian length prefix shared by both ends.
 *
 * @see simble_protocol.h for the API documentation, and SPEC.md for the frame format.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "simble_protocol.h"

#include <string.h>

int simble_frame(const uint8_t *payload, size_t len, uint8_t *out, size_t cap) {
  if (len > SIMBLE_MAX_FRAME)
    return -1;
  if (cap < len + 4)
    return -1;
  out[0] = (uint8_t)(len >> 24);
  out[1] = (uint8_t)(len >> 16);
  out[2] = (uint8_t)(len >> 8);
  out[3] = (uint8_t)len;
  memcpy(out + 4, payload, len);
  return (int)(len + 4);
}

long simble_payload_length(const uint8_t prefix[4]) {
  // Unsigned assembly: a signed shift of prefix[0] >= 0x80 would be negative on a
  // 32-bit long. Apple targets are 64-bit, but the codec stays width-clean.
  uint32_t len = ((uint32_t)prefix[0] << 24) | ((uint32_t)prefix[1] << 16) |
                 ((uint32_t)prefix[2] << 8) | (uint32_t)prefix[3];
  if (len > SIMBLE_MAX_FRAME)
    return -1;
  return (long)len;
}
