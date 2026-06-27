/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file entry.c
 * @brief The dylib constructor: installs the central swizzles at load, inert without
 *        configuration.
 *
 * @details
 * dyld runs the constructor when the dylib loads, before the app's main, so the
 * CoreBluetooth central swizzles are in place before any CBCentralManager call. Loaded
 * only via the debug scheme's dyld insert list; a release build bundles no dylib at all,
 * which is the fence, not this gate.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "simble_interpose.h"

#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void simble_interpose_init(void) {
  // Inert without the dev-scheme env (SIMBLE_PORT, SIMBLE_TOKEN). Not the fence; a release build
  // bundles no dylib.
  if (!getenv("SIMBLE_PORT") || !getenv("SIMBLE_TOKEN"))
    return;
  int failures = simble_install_hooks();
  if (failures != 0) {
    fprintf(stderr, "[simble] %d swizzle(s) failed to install\n", failures);
  }
}
