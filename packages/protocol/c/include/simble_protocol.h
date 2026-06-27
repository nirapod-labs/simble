/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file simble_protocol.h
 * @brief SimBLE wire protocol, C side: encoders, decoders, length framing.
 *
 * @details
 * The interposer encodes requests and decodes responses and events with this; the
 * Swift helper is the other end. The wire is CBOR maps with unsigned-integer keys
 * inside a 4-byte big-endian length-prefixed frame (see SPEC.md and protocol.cddl
 * two directories up). The codec is hand-written and byte-matches the Swift one.
 *
 * Every encoder writes a complete request payload (CBOR, no frame) into a caller
 * buffer and returns the byte count, or -1 when the buffer is too small. Encoders
 * never allocate.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#ifndef SIMBLE_PROTOCOL_H
#define SIMBLE_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @defgroup simble_protocol Wire protocol (C codec)
 * @brief Request encoders, response and event decoders, frame helpers.
 * @{
 */

/** Current wire protocol version. */
#define SIMBLE_PROTOCOL_VERSION 1

/** Largest frame either end accepts: 1 MiB, matching the Swift codec. */
#define SIMBLE_MAX_FRAME (1 << 20)

/** Report the wire protocol version this package exposes. */
int simble_protocol_version(void);

/** Decoder result. Anything but ::SIMBLE_OK means the payload was rejected. */
typedef enum {
  SIMBLE_OK = 0,        ///< Decoded cleanly.
  SIMBLE_ERR_TRUNCATED, ///< Payload ended inside a value.
  SIMBLE_ERR_MALFORMED, ///< Not canonical CBOR: duplicate key, non-shortest form, or trailing
                        ///< bytes.
  SIMBLE_ERR_TYPE,      ///< A value carried the wrong CBOR major type.
  SIMBLE_ERR_OPCODE,    ///< The op (key 0) is not one this codec knows.
  SIMBLE_ERR_STATUS,    ///< The status (key 1) is neither OK nor ERROR.
  SIMBLE_ERR_MISSING,   ///< A field the op requires is absent.
  SIMBLE_ERR_BUFFER,    ///< A field exceeds its fixed buffer in a decode struct.
} simble_status;

/** How a central writes a characteristic, mirroring CBCharacteristicWriteType. */
typedef enum {
  SIMBLE_WRITE_WITH_RESPONSE = 0,    ///< The write expects a host acknowledgement.
  SIMBLE_WRITE_WITHOUT_RESPONSE = 1, ///< The write expects no acknowledgement.
} simble_write_type;

/**
 * @brief Encode a HELLO request.
 *
 * HELLO carries the connecting app's identity once, so the helper can show it: the guest bundle
 * id (key 14) and display name (key 28). Each is included only when its length is non-zero. The
 * identity is guest-reported, names the app for display, and gates nothing.
 *
 * @param[in]  token            32-byte capability token.
 * @param[in]  token_len        Length of @p token; the helper only accepts 32.
 * @param[in]  version          Protocol version offered; currently 1.
 * @param[in]  app_id           Guest bundle id, UTF-8 (key 14), or NULL.
 * @param[in]  app_id_len       Length of @p app_id; 0 omits key 14.
 * @param[in]  display_name     Guest display name, UTF-8 (key 28), or NULL.
 * @param[in]  display_name_len Length of @p display_name; 0 omits key 28.
 * @param[out] out              Buffer the payload is written to.
 * @param[in]  cap              Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_hello(const uint8_t *token, size_t token_len, uint64_t version,
                        const uint8_t *app_id, size_t app_id_len, const uint8_t *display_name,
                        size_t display_name_len, uint8_t *out, size_t cap);

/**
 * @brief Encode a token-only request.
 *
 * Used by CENTRAL_STATE, SCAN_STOP, and STOP_ADVERTISING.
 *
 * @param[in]  op        Op code (a command op in 1 through 20).
 * @param[in]  token     32-byte capability token.
 * @param[in]  token_len Length of @p token.
 * @param[out] out       Buffer the payload is written to.
 * @param[in]  cap       Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_command(uint64_t op, const uint8_t *token, size_t token_len, uint8_t *out,
                          size_t cap);

/**
 * @brief Encode a peripheral-directed request.
 *
 * Used by CONNECT, DISCONNECT, READ_RSSI, and PERIPHERAL_STATE.
 *
 * @param[in]  op             Op code.
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host CBPeripheral.identifier bytes (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_peripheral_command(uint64_t op, const uint8_t *token, size_t token_len,
                                     const uint8_t *peripheral_id, size_t peripheral_len,
                                     uint8_t *out, size_t cap);

/**
 * @brief Encode a SCAN_START request.
 *
 * @param[in]  token       32-byte capability token.
 * @param[in]  token_len   Length of @p token.
 * @param[in]  uuids       Array of UTF-8 service UUID strings to filter on, or NULL for no filter.
 * @param[in]  uuid_lens   Per-UUID lengths, parallel to @p uuids.
 * @param[in]  uuid_count  Number of UUIDs; 0 omits key 50.
 * @param[out] out         Buffer the payload is written to.
 * @param[in]  cap         Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_scan_start(const uint8_t *token, size_t token_len, const char *const *uuids,
                             const size_t *uuid_lens, size_t uuid_count, uint8_t *out, size_t cap);

/**
 * @brief Encode a DISCOVER_SERVICES request.
 *
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host peripheral identifier (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  uuids          Array of UTF-8 service UUID strings to filter on, or NULL.
 * @param[in]  uuid_lens      Per-UUID lengths, parallel to @p uuids.
 * @param[in]  uuid_count     Number of UUIDs; 0 omits key 50.
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_discover_services(const uint8_t *token, size_t token_len,
                                    const uint8_t *peripheral_id, size_t peripheral_len,
                                    const char *const *uuids, const size_t *uuid_lens,
                                    size_t uuid_count, uint8_t *out, size_t cap);

/**
 * @brief Encode a DISCOVER_CHARACTERISTICS request.
 *
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host peripheral identifier (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8 (key 31).
 * @param[in]  service_len    Length of @p service.
 * @param[in]  uuids          Array of UTF-8 characteristic UUID strings to filter on, or NULL.
 * @param[in]  uuid_lens      Per-UUID lengths, parallel to @p uuids.
 * @param[in]  uuid_count     Number of UUIDs; 0 omits key 51.
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_discover_characteristics(const uint8_t *token, size_t token_len,
                                           const uint8_t *peripheral_id, size_t peripheral_len,
                                           const char *service, size_t service_len,
                                           const char *const *uuids, const size_t *uuid_lens,
                                           size_t uuid_count, uint8_t *out, size_t cap);

/**
 * @brief Encode a READ_CHARACTERISTIC request.
 *
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host peripheral identifier (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8 (key 31).
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8 (key 32).
 * @param[in]  char_len       Length of @p characteristic.
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_read_characteristic(const uint8_t *token, size_t token_len,
                                      const uint8_t *peripheral_id, size_t peripheral_len,
                                      const char *service, size_t service_len,
                                      const char *characteristic, size_t char_len, uint8_t *out,
                                      size_t cap);

/**
 * @brief Encode a WRITE_CHARACTERISTIC request.
 *
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host peripheral identifier (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8 (key 31).
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8 (key 32).
 * @param[in]  char_len       Length of @p characteristic.
 * @param[in]  value          Value bytes to write (key 33).
 * @param[in]  value_len      Length of @p value.
 * @param[in]  write_type     A ::simble_write_type (key 39).
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_write_characteristic(const uint8_t *token, size_t token_len,
                                       const uint8_t *peripheral_id, size_t peripheral_len,
                                       const char *service, size_t service_len,
                                       const char *characteristic, size_t char_len,
                                       const uint8_t *value, size_t value_len,
                                       simble_write_type write_type, uint8_t *out, size_t cap);

/**
 * @brief Encode a SET_NOTIFY request.
 *
 * @param[in]  token          32-byte capability token.
 * @param[in]  token_len      Length of @p token.
 * @param[in]  peripheral_id  Host peripheral identifier (key 30).
 * @param[in]  peripheral_len Length of @p peripheral_id.
 * @param[in]  service        Service UUID, UTF-8 (key 31).
 * @param[in]  service_len    Length of @p service.
 * @param[in]  characteristic Characteristic UUID, UTF-8 (key 32).
 * @param[in]  char_len       Length of @p characteristic.
 * @param[in]  enabled        Non-zero enables notifications (key 40 = 1).
 * @param[out] out            Buffer the payload is written to.
 * @param[in]  cap            Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_set_notify(const uint8_t *token, size_t token_len, const uint8_t *peripheral_id,
                             size_t peripheral_len, const char *service, size_t service_len,
                             const char *characteristic, size_t char_len, int enabled, uint8_t *out,
                             size_t cap);

/**
 * @brief Encode a RESPOND_READ request.
 *
 * @param[in]  token      32-byte capability token.
 * @param[in]  token_len  Length of @p token.
 * @param[in]  request_id Request id correlating the incoming READ_REQUEST event (key 42).
 * @param[in]  value      Value bytes to return (key 33).
 * @param[in]  value_len  Length of @p value.
 * @param[in]  att_error  ATT result code (key 49); 0 is success.
 * @param[out] out        Buffer the payload is written to.
 * @param[in]  cap        Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_respond_read(const uint8_t *token, size_t token_len, uint64_t request_id,
                               const uint8_t *value, size_t value_len, uint64_t att_error,
                               uint8_t *out, size_t cap);

/**
 * @brief Encode a RESPOND_WRITE request.
 *
 * @param[in]  token      32-byte capability token.
 * @param[in]  token_len  Length of @p token.
 * @param[in]  request_id Request id correlating the incoming WRITE_REQUEST event (key 42).
 * @param[in]  att_error  ATT result code (key 49); 0 is success.
 * @param[out] out        Buffer the payload is written to.
 * @param[in]  cap        Capacity of @p out.
 * @return Bytes written, or -1 if @p cap is too small.
 */
int simble_encode_respond_write(const uint8_t *token, size_t token_len, uint64_t request_id,
                                uint64_t att_error, uint8_t *out, size_t cap);

/** Which response the helper sent, after ::simble_decode_response dispatches on op and status. */
typedef enum {
  SIMBLE_RESP_HELLO,         ///< HELLO ok: version is set.
  SIMBLE_RESP_CENTRAL_STATE, ///< CENTRAL_STATE ok: manager_state is set.
  SIMBLE_RESP_CONFIRMED,     ///< A status-only confirmation (scan start/stop, write, advertising,
                             ///< respond, update). The echoed op is in resp_op.
  SIMBLE_RESP_PERIPHERAL,    ///< A peripheral-id reply (connect, disconnect). peripheral is set.
  SIMBLE_RESP_RSSI,          ///< READ_RSSI ok: peripheral and rssi are set.
  SIMBLE_RESP_PERIPHERAL_STATE, ///< PERIPHERAL_STATE ok: peripheral and manager_state are set.
  SIMBLE_RESP_CHAR_VALUE,       ///< READ_CHARACTERISTIC ok: peripheral, service, characteristic,
                                ///< value are set.
  SIMBLE_RESP_NOTIFY_STATE,     ///< SET_NOTIFY ok: peripheral, service, characteristic, notify set.
  SIMBLE_RESP_SERVICES_DISCOVERED, ///< DISCOVER_SERVICES ok: peripheral and the uuids list are set.
  SIMBLE_RESP_CHARS_DISCOVERED, ///< DISCOVER_CHARACTERISTICS ok: peripheral, service, and the uuids
                                ///< list are set.
  SIMBLE_RESP_ERROR,            ///< The helper returned an error: error and error_code are set.
} simble_resp_kind;

/** The most discovered UUIDs a single discover response surfaces. */
#define SIMBLE_MAX_UUIDS 32

/** The buffer a single discovered UUID is copied into, NUL-terminated. */
#define SIMBLE_UUID_CAP 40

/**
 * A decoded response. Fixed buffers, no ownership: the decoder copies out of the
 * payload, and lengths say how much of each buffer is meaningful for the kind.
 */
typedef struct {
  simble_resp_kind kind;   ///< Which response this is; selects the fields below.
  uint64_t resp_op;        ///< The echoed op in key 0.
  uint64_t version;        ///< Protocol version on a HELLO response.
  uint64_t manager_state;  ///< CBManagerState on CENTRAL_STATE / PERIPHERAL_STATE.
  uint8_t peripheral[64];  ///< Peripheral identifier bytes.
  size_t peripheral_len;   ///< Meaningful bytes in @c peripheral.
  char service[64];        ///< Service UUID, NUL-terminated.
  char characteristic[64]; ///< Characteristic UUID, NUL-terminated.
  uint8_t value[1024];     ///< Characteristic value bytes.
  size_t value_len;        ///< Meaningful bytes in @c value.
  int64_t rssi;            ///< RSSI on a READ_RSSI response.
  int notify;              ///< Notification state on a SET_NOTIFY response: 0 or 1.
  char uuids[SIMBLE_MAX_UUIDS][SIMBLE_UUID_CAP]; ///< Discovered UUIDs, NUL-terminated, on a
                                                 ///< discover response.
  size_t uuid_count;                             ///< Meaningful entries in @c uuids.
  char error[256];    ///< NUL-terminated reason on an error; never load-bearing.
  int64_t error_code; ///< CBError/CBATTError code on an error response, 0 otherwise.
} simble_response;

/**
 * @brief Decode a response payload, dispatching on op and status.
 *
 * Rejects anything that is not canonical CBOR: duplicate keys, non-shortest
 * integer or length forms, and trailing bytes all fail with ::SIMBLE_ERR_MALFORMED.
 *
 * @param[in]  payload Response payload (CBOR, no frame).
 * @param[in]  len     Length of @p payload.
 * @param[out] out     Decoded response; meaningful fields depend on @c out->kind.
 * @retval SIMBLE_OK on a clean decode; a ::simble_status error otherwise.
 */
simble_status simble_decode_response(const uint8_t *payload, size_t len, simble_response *out);

/** Which event the helper raised, after ::simble_decode_event dispatches on op. */
typedef enum {
  SIMBLE_EVT_DISCOVERED,               ///< A peripheral seen while scanning.
  SIMBLE_EVT_CHAR_VALUE,               ///< A characteristic notification value (central role).
  SIMBLE_EVT_DISCONNECTED,             ///< An unsolicited disconnect.
  SIMBLE_EVT_CENTRAL_STATE_CHANGED,    ///< The central manager state changed.
  SIMBLE_EVT_PERIPHERAL_STATE_CHANGED, ///< The peripheral manager state changed.
  SIMBLE_EVT_READ_REQUEST,             ///< An incoming read from a central (peripheral role).
  SIMBLE_EVT_WRITE_REQUEST,            ///< An incoming write from a central (peripheral role).
  SIMBLE_EVT_SUBSCRIBED,               ///< A central subscribed (peripheral role).
  SIMBLE_EVT_UNSUBSCRIBED,             ///< A central unsubscribed (peripheral role).
  SIMBLE_EVT_READY_TO_UPDATE,          ///< The transmit queue has room again (peripheral role).
} simble_evt_kind;

/**
 * A decoded event. Fixed buffers, no ownership. Lengths and the presence flags
 * say which fields are meaningful for the ::simble_evt_kind in @c kind.
 */
typedef struct {
  simble_evt_kind kind;   ///< Which event this is; selects the fields below.
  uint64_t evt_op;        ///< The event op in key 0.
  uint8_t peripheral[64]; ///< Peripheral identifier bytes (DISCOVERED, CHAR_VALUE, DISCONNECTED).
  size_t peripheral_len;  ///< Meaningful bytes in @c peripheral.
  uint8_t central[64]; ///< Subscribing central id (READ/WRITE_REQUEST, SUBSCRIBED, UNSUBSCRIBED).
  size_t central_len;  ///< Meaningful bytes in @c central.
  char service[64];    ///< Service UUID, NUL-terminated.
  char characteristic[64]; ///< Characteristic UUID, NUL-terminated.
  uint8_t value[1024];     ///< Value bytes (CHAR_VALUE, WRITE_REQUEST).
  size_t value_len;        ///< Meaningful bytes in @c value.
  int64_t rssi;            ///< RSSI on a DISCOVERED event.
  char local_name[64];     ///< Advertised local name, NUL-terminated (DISCOVERED).
  int has_local_name;      ///< Non-zero when @c local_name is present.
  int64_t tx_power;        ///< Advertised TX power (DISCOVERED).
  int has_tx_power;        ///< Non-zero when @c tx_power is present.
  uint8_t mfg_data[256];   ///< Advertised manufacturer data (DISCOVERED).
  size_t mfg_data_len;     ///< Meaningful bytes in @c mfg_data.
  int has_mfg_data;        ///< Non-zero when @c mfg_data is present.
  uint64_t manager_state;  ///< CBManagerState (CENTRAL/PERIPHERAL_STATE_CHANGED).
  uint64_t request_id;     ///< Request id (READ_REQUEST, WRITE_REQUEST).
  uint64_t att_offset;     ///< ATT offset (READ_REQUEST, WRITE_REQUEST).
  uint64_t mtu;            ///< Maximum update value length (SUBSCRIBED).
  int64_t error_code;      ///< CBError on a DISCONNECTED event, 0 otherwise.
  int has_error_code;      ///< Non-zero when a disconnect carried an error code.
} simble_event;

/**
 * @brief Decode an event payload, dispatching on the event op (key 0).
 *
 * @param[in]  payload Event payload (CBOR, no frame).
 * @param[in]  len     Length of @p payload.
 * @param[out] out     Decoded event; meaningful fields depend on @c out->kind.
 * @retval SIMBLE_OK on a clean decode; a ::simble_status error otherwise.
 */
simble_status simble_decode_event(const uint8_t *payload, size_t len, simble_event *out);

/**
 * @brief Frame a payload: a 4-byte big-endian length prefix, then the bytes.
 *
 * @param[in]  payload Payload to frame.
 * @param[in]  len     Length of @p payload; at most ::SIMBLE_MAX_FRAME.
 * @param[out] out     Buffer the frame is written to.
 * @param[in]  cap     Capacity of @p out; needs @p len + 4.
 * @return Bytes written (len + 4), or -1 if @p len exceeds ::SIMBLE_MAX_FRAME or @p cap is too
 * small.
 */
int simble_frame(const uint8_t *payload, size_t len, uint8_t *out, size_t cap);

/**
 * @brief Parse a 4-byte big-endian length prefix.
 *
 * @param[in] prefix The 4 prefix bytes.
 * @return The payload length, or -1 if it exceeds ::SIMBLE_MAX_FRAME.
 */
long simble_payload_length(const uint8_t prefix[4]);

/** @} */

#ifdef __cplusplus
}
#endif

#endif
