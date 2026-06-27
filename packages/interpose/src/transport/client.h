/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file client.h
 * @brief Loopback transport to the helper: one framed request per call, a decoded
 *        reply out.
 *
 * @details
 * Connects to 127.0.0.1 at the port named by SIMBLE_PORT, sends one framed request
 * carrying the capability token from SIMBLE_TOKEN in key 7, reads one 4-byte
 * big-endian length-prefixed reply, and decodes it with the simble_protocol C codec.
 * One connection per request. A reply is a response or an unsolicited event; the
 * request functions return responses, and ::simble_client_read_event drains the
 * stream of events a long-lived connection carries.
 *
 * Every function returns the codec's ::simble_status. A missing or malformed port
 * or token, a failed connect, and a short read surface as ::SIMBLE_ERR_TRUNCATED;
 * an oversized frame as ::SIMBLE_ERR_BUFFER; a bad length prefix as
 * ::SIMBLE_ERR_MALFORMED.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#ifndef SIMBLE_CLIENT_H
#define SIMBLE_CLIENT_H

#include "simble_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @defgroup simble_client Loopback client
 * @brief One-shot request functions and an event-stream reader the hooks use.
 * @{
 */

/** An open connection to the helper, for a path that reads events after a request. */
typedef struct {
  int fd; ///< The connected socket, or -1 when not open.
} simble_conn;

/**
 * @brief Run the HELLO version handshake, announcing the guest's identity for display.
 *
 * The identity is optional and best-effort: the bundle id and display name, each omitted when
 * its pointer is NULL or length is 0. It names the connecting app so the helper can show it and
 * gates nothing; the helper sanitizes the name before use.
 *
 * @param[in]  version          Protocol version this side speaks.
 * @param[in]  app_id           Guest bundle id, UTF-8, or NULL.
 * @param[in]  app_id_len       Length of @p app_id; 0 omits it.
 * @param[in]  display_name     Guest display name, UTF-8, or NULL.
 * @param[in]  display_name_len Length of @p display_name; 0 omits it.
 * @param[out] out              The decoded response; ::SIMBLE_RESP_HELLO on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_hello(uint64_t version, const uint8_t *app_id, size_t app_id_len,
                                  const uint8_t *display_name, size_t display_name_len,
                                  simble_response *out);

/**
 * @brief Read the host central manager's CBManagerState.
 *
 * @param[out] out The decoded response; ::SIMBLE_RESP_CENTRAL_STATE on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_central_state(simble_response *out);

/**
 * @brief Begin scanning, optionally filtered to a set of service UUIDs.
 *
 * @param[in]  uuids      Array of UTF-8 service UUID strings, or NULL for no filter.
 * @param[in]  uuid_lens  Per-UUID lengths, parallel to @p uuids.
 * @param[in]  uuid_count Number of UUIDs; 0 omits the filter.
 * @param[out] out        The decoded response; ::SIMBLE_RESP_CONFIRMED on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_scan_start(const char *const *uuids, const size_t *uuid_lens,
                                       size_t uuid_count, simble_response *out);

/**
 * @brief End scanning.
 *
 * @param[out] out The decoded response; ::SIMBLE_RESP_CONFIRMED on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_scan_stop(simble_response *out);

/**
 * @brief Connect to a peripheral named by its host identifier.
 *
 * @param[in]  peripheral_id  Host CBPeripheral.identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_PERIPHERAL on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_connect(const uint8_t *peripheral_id, size_t peripheral_len,
                                    simble_response *out);

/**
 * @brief Disconnect a peripheral named by its host identifier.
 *
 * @param[in]  peripheral_id  Host peripheral identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_PERIPHERAL on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_disconnect(const uint8_t *peripheral_id, size_t peripheral_len,
                                       simble_response *out);

/**
 * @brief Read a characteristic value from a connected peripheral.
 *
 * @param[in]  peripheral_id  Host peripheral identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8.
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8.
 * @param[in]  char_len       Length of @p characteristic.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_CHAR_VALUE on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_read_characteristic(const uint8_t *peripheral_id, size_t peripheral_len,
                                                const char *service, size_t service_len,
                                                const char *characteristic, size_t char_len,
                                                simble_response *out);

/**
 * @brief Write a characteristic value to a connected peripheral, with or without a response.
 *
 * @param[in]  peripheral_id  Host peripheral identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8.
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8.
 * @param[in]  char_len       Length of @p characteristic.
 * @param[in]  value          Value bytes to write.
 * @param[in]  value_len      Length of @p value.
 * @param[in]  write_type     A ::simble_write_type.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_CONFIRMED on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_write_characteristic(const uint8_t *peripheral_id,
                                                 size_t peripheral_len, const char *service,
                                                 size_t service_len, const char *characteristic,
                                                 size_t char_len, const uint8_t *value,
                                                 size_t value_len, simble_write_type write_type,
                                                 simble_response *out);

/**
 * @brief Enable or disable notifications on a characteristic.
 *
 * @param[in]  peripheral_id  Host peripheral identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8.
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8.
 * @param[in]  char_len       Length of @p characteristic.
 * @param[in]  enabled        Non-zero enables notifications.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_NOTIFY_STATE on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_set_notify(const uint8_t *peripheral_id, size_t peripheral_len,
                                       const char *service, size_t service_len,
                                       const char *characteristic, size_t char_len, int enabled,
                                       simble_response *out);

/**
 * @brief Read a connected peripheral's signal strength.
 *
 * @param[in]  peripheral_id  Host peripheral identifier bytes.
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[out] out            The decoded response; ::SIMBLE_RESP_RSSI on success.
 * @return ::SIMBLE_OK when a response decoded cleanly, a ::simble_status error otherwise.
 */
simble_status simble_client_read_rssi(const uint8_t *peripheral_id, size_t peripheral_len,
                                      simble_response *out);

/**
 * @brief Open a connection to the helper, for a path that reads events after sending a request.
 *
 * The hooks use the one-shot request functions for directed operations; the event stream the
 * helper raises unsolicited (a scan result, a notification, a disconnect) is read from a
 * connection opened here and drained with ::simble_client_read_event.
 *
 * @param[out] conn Set to the open connection on success.
 * @return ::SIMBLE_OK on a connect, ::SIMBLE_ERR_TRUNCATED when the port or token is absent or the
 *         connect failed.
 */
simble_status simble_client_open(simble_conn *conn);

/**
 * @brief Read and decode one event frame from an open connection.
 *
 * Blocks until a frame arrives or the connection closes. The reply is decoded as an event; a frame
 * that is a response rather than an event is reported as ::SIMBLE_ERR_OPCODE.
 *
 * @param[in]  conn The connection opened with ::simble_client_open.
 * @param[out] out  The decoded event.
 * @return ::SIMBLE_OK on a clean event, a ::simble_status error otherwise.
 */
simble_status simble_client_read_event(simble_conn *conn, simble_event *out);

/**
 * @brief Close an open connection.
 *
 * @param[in,out] conn The connection to close; its fd is reset to -1.
 */
void simble_client_close(simble_conn *conn);

/** @} */

#ifdef __cplusplus
}
#endif

#endif
