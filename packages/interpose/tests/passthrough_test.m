/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file passthrough_test.m
 * @brief The passthrough invariant as a first-class test.
 *
 * @details
 * A CBCentralManager the registry did not mint is unaffected by the installed swizzle: the
 * routed methods consult the registry, miss, and call the original implementation. The test
 * proves the managed split by registry membership, then drives a non-managed manager's swizzled
 * methods and confirms its state reads the same with the swizzle installed as without it, with
 * no radio and no helper.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#import "../include/simble_interpose.h"
#import "shadow.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <stdio.h>

static int fails = 0;
#define CHECK(cond, msg)                                                                           \
  do {                                                                                             \
    if (!(cond)) {                                                                                 \
      printf("FAIL: %s\n", msg);                                                                   \
      fails++;                                                                                     \
    }                                                                                              \
  } while (0)

int main(void) {
  @autoreleasepool {
    simble_shadow_reset();

    // A manager the registry never registered, the non-managed receiver. Its state before any
    // swizzle is the baseline.
    CBCentralManager *stray = [CBCentralManager alloc];
    CBManagerState before = stray.state;

    int failures = simble_install_hooks();
    CHECK(failures == 0, "swizzles install");

    // The routed methods gate on registry membership. A stray manager is not managed, so the
    // swizzled state reads the original value, byte-identical to the pre-install read.
    CHECK(!simble_shadow_is_managed_manager(stray), "a stray manager is not managed");
    CBManagerState after = stray.state;
    printf("stray state: %ld == %ld\n", (long)before, (long)after);
    CHECK(before == after, "a non-managed manager's state is unaffected by the swizzle");

    // Non-managed scan/stop reach the original implementation; the routed counter must not move.
    simble_hook_stats start = simble_get_hook_stats();
    [stray scanForPeripheralsWithServices:nil options:nil];
    [stray stopScan];
    simble_hook_stats end = simble_get_hook_stats();
    CHECK(start.scan_start == end.scan_start, "a non-managed scan does not count as routed");

    // The peripheral surface gates on the same registry predicate: a stray peripheral manager is
    // not managed, a registered one is.
    CBPeripheralManager *strayPeripheral = [CBPeripheralManager alloc];
    CHECK(!simble_shadow_is_managed_peripheral_manager(strayPeripheral),
          "a stray peripheral manager is not managed");

    // A managed peripheral manager routes addService:, moving the counter. The transport call fails
    // closed without a helper; the route still fired.
    CBMutableService *service =
        [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:@"180D"] primary:YES];
    CBPeripheralManager *managedPeripheral = [CBPeripheralManager alloc];
    simble_shadow_register_peripheral_manager(managedPeripheral, nil, nil);
    CHECK(simble_shadow_is_managed_peripheral_manager(managedPeripheral),
          "a registered peripheral manager is managed");
    simble_hook_stats pStart = simble_get_hook_stats();
    [managedPeripheral addService:service];
    simble_hook_stats pManaged = simble_get_hook_stats();
    CHECK(pManaged.add_service == pStart.add_service + 1, "a managed addService counts as routed");

    simble_uninstall_hooks();
    simble_shadow_reset();
  }

  printf(fails ? "PASSTHROUGH: %d failure(s)\n" : "PASSTHROUGH: ok\n", fails);
  return fails ? 1 : 0;
}
