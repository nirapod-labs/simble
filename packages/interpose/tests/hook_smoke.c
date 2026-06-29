/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file hook_smoke.c
 * @brief The swizzles install and uninstall cleanly on the host.
 *
 * @details
 * The host has the CoreBluetooth classes the swizzles target, so a plain ctest can install
 * every central and peripheral swizzle, confirm none failed, and uninstall, with no radio and no
 * helper. The version entry point is checked too. A non-zero install count means some selector,
 * central or peripheral, did not swizzle.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "simble_interpose.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
  assert(simble_interpose_version() == 1);

  // The counters start at zero before any routed call.
  simble_hook_stats fresh = simble_get_hook_stats();
  assert(fresh.add_service == 0 && fresh.start_advertising == 0 && fresh.respond == 0 &&
         fresh.update_value == 0 && fresh.peripheral_event == 0);

  int failures = simble_install_hooks();
  printf("install: %d swizzle(s) failed\n", failures);
  if (failures != 0)
    return 1;

  // Idempotent: a second install while installed is a no-op and reports no failures.
  if (simble_install_hooks() != 0)
    return 1;

  simble_uninstall_hooks();
  // Idempotent: an uninstall while nothing is installed is a no-op.
  simble_uninstall_hooks();

  // Reinstall after uninstall, to prove the exchange restored a swizzleable original.
  if (simble_install_hooks() != 0)
    return 1;
  simble_uninstall_hooks();

  printf("HOOK SMOKE: ok\n");
  return 0;
}
