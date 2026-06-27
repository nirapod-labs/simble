/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

#include "simble_protocol.h"

#include <assert.h>

int main(void) {
  assert(simble_protocol_version() == SIMBLE_PROTOCOL_VERSION);
  return 0;
}
