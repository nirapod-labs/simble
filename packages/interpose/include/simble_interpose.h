/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file simble_interpose.h
 * @brief The injected interposer's entry points: swizzle installation and the
 *        route-fire counters.
 *
 * @details
 * The dylib's constructor calls ::simble_install_hooks at load when the environment
 * is configured (SIMBLE_PORT and SIMBLE_TOKEN present) and stays inert otherwise.
 * Counters a host harness reads to confirm the swizzles fired.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#ifndef SIMBLE_INTERPOSE_H
#define SIMBLE_INTERPOSE_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @defgroup simble_interpose Interposer entry points
 * @brief Swizzle installation, uninstall, and the route counters.
 * @{
 */

/** Return the interposer scaffold version. */
int simble_interpose_version(void);

/**
 * @brief Install the CoreBluetooth central and peripheral swizzles.
 *
 * Exchanges the CBCentralManager, CBPeripheral, and CBPeripheralManager method implementations for
 * the routed ones. Idempotent: a second call is a no-op while the swizzles are installed.
 *
 * @return The number of selectors that could not be swizzled; 0 means every one is in place.
 */
int simble_install_hooks(void);

/**
 * @brief Remove the swizzles, restoring the original method implementations.
 *
 * Idempotent: a call while nothing is installed is a no-op.
 */
void simble_uninstall_hooks(void);

/** How many times each routed operation has fired since install. */
typedef struct {
  int scan_start;               ///< scanForPeripheralsWithServices:options: calls routed.
  int connect;                  ///< connectPeripheral:options: calls routed to the helper.
  int discover_services;        ///< discoverServices: calls routed to the helper.
  int discover_characteristics; ///< discoverCharacteristics:forService: calls routed.
  int read;                     ///< readValueForCharacteristic: calls routed to the helper.
  int write;                    ///< writeValue:forCharacteristic:type: calls routed.
  int set_notify;               ///< setNotifyValue:forCharacteristic: calls routed.
  int add_service;              ///< addService: calls routed to the helper.
  int remove_service;           ///< removeService: and removeAllServices: calls routed.
  int start_advertising;        ///< startAdvertising: calls routed to the helper.
  int respond;                  ///< respondToRequest:withResult: calls routed.
  int update_value;             ///< updateValue:forCharacteristic:onSubscribedCentrals: calls routed.
  int peripheral_event;         ///< peripheral events delivered to the guest delegate.
} simble_hook_stats;

/**
 * @brief Read the route-fire counters.
 *
 * @return A copy of the counters at the time of the call.
 */
simble_hook_stats simble_get_hook_stats(void);

/** @} */

#ifdef __cplusplus
}
#endif

#endif
