/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file hooks_internal.h
 * @brief Shared swizzle plumbing across the central and peripheral hook units.
 *
 * @details
 * The central unit owns the route counters, the swizzle exchange, and the event reader; the
 * peripheral unit reuses them through these declarations. Not a public header.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#ifndef SIMBLE_HOOKS_INTERNAL_H
#define SIMBLE_HOOKS_INTERNAL_H

#import "simble_interpose.h"
#import "simble_protocol.h"

#import <objc/runtime.h>

/**
 * @brief Exchange original and routed IMPs for a selector, recording the pair for uninstall.
 *
 * @param[in] cls         The class carrying the selector.
 * @param[in] original    The selector to route.
 * @param[in] replacement The routed selector.
 * @return 0 on success, -1 when either method is absent.
 */
int simble_swizzle(Class cls, SEL original, SEL replacement);

/** @brief The shared route counters the public simble_get_hook_stats reads. */
simble_hook_stats *simble_internal_stats(void);

/**
 * @brief Install the CBPeripheralManager swizzles.
 *
 * @return The number of selectors that failed to swizzle.
 */
int simble_install_peripheral_hooks(void);

/**
 * @brief Translate one peripheral-role host event into the guest's delegate callbacks.
 *
 * @param[in] event The decoded peripheral event.
 */
void simble_deliver_peripheral_event(const simble_event *event);

#endif
