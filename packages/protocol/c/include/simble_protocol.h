/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file simble_protocol.h
 * @brief Public constants for the SimBLE wire protocol package.
 */

#ifndef SIMBLE_PROTOCOL_H
#define SIMBLE_PROTOCOL_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Current scaffold protocol version.
 */
#define SIMBLE_PROTOCOL_VERSION 1

/** Report the wire protocol version this scaffold package exposes. */
int simble_protocol_version(void);

#ifdef __cplusplus
}
#endif

#endif
