/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

#include "simble_interpose.h"

#include <assert.h>

int main(void) {
  assert(simble_interpose_version() == 1);
  return 0;
}
