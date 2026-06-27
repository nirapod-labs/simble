/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

#include "simble_interpose.h"

int simble_interpose_version(void) { return 1; }

__attribute__((constructor)) static void simble_interpose_init(void) {}
