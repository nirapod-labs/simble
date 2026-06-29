/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file simble_protocol.c
 * @brief Hand-written canonical CBOR: the request encoders and the response and
 *        event decoders.
 *
 * @details
 * Minimal CBOR for the protocol's messages: unsigned ints, negative ints, byte
 * strings, text strings, a definite-length array of text strings, and a
 * definite-length map with unsigned-integer keys. Emits the shortest form, the
 * canonical encoding, so it byte-matches the Swift codec.
 *
 * @see simble_protocol.h for the API documentation.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "simble_protocol.h"

#include <limits.h>
#include <string.h>

int simble_protocol_version(void) { return SIMBLE_PROTOCOL_VERSION; }

// keys: shared with the SimEnclave wire for op/status/error/token/version/errorCode/appId/display,
// then the BLE fields from 30 up. See SPEC.md and protocol.cddl for the full table.
enum {
  K_OP = 0,
  K_STATUS = 1,
  K_ERR = 6,
  K_TOKEN = 7,
  K_VERSION = 8,
  K_ERR_CODE = 10,
  K_APP_ID = 14,
  K_DISPLAY_NAME = 28,
  K_PERIPHERAL = 30,
  K_SERVICE = 31,
  K_CHARACTERISTIC = 32,
  K_VALUE = 33,
  K_RSSI = 34,
  K_LOCAL_NAME = 35,
  K_ADV_SERVICE_UUIDS = 36,
  K_TX_POWER = 37,
  K_MFG_DATA = 38,
  K_WRITE_TYPE = 39,
  K_NOTIFY = 40,
  K_MANAGER_STATE = 41,
  K_REQUEST_ID = 42,
  K_ATT_OFFSET = 43,
  K_CHAR_PROPERTIES = 44,
  K_ATT_PERMISSIONS = 45,
  K_IS_PRIMARY = 46,
  K_CENTRAL = 47,
  K_MTU = 48,
  K_ATT_ERROR = 49,
  K_SERVICE_UUIDS = 50,
  K_CHARACTERISTIC_UUIDS = 51,
};

// command ops (request and response share one op), event ops at 128+, and status values
enum {
  OP_HELLO = 1,
  OP_CENTRAL_STATE = 2,
  OP_SCAN_START = 3,
  OP_SCAN_STOP = 4,
  OP_CONNECT = 5,
  OP_DISCONNECT = 6,
  OP_DISCOVER_SERVICES = 7,
  OP_DISCOVER_CHARACTERISTICS = 8,
  OP_READ_CHARACTERISTIC = 9,
  OP_WRITE_CHARACTERISTIC = 10,
  OP_SET_NOTIFY = 11,
  OP_READ_RSSI = 12,
  OP_PERIPHERAL_STATE = 13,
  OP_ADD_SERVICE = 14,
  OP_REMOVE_SERVICE = 15,
  OP_START_ADVERTISING = 16,
  OP_STOP_ADVERTISING = 17,
  OP_RESPOND_READ = 18,
  OP_RESPOND_WRITE = 19,
  OP_UPDATE_VALUE = 20,
  OP_EVT_DISCOVERED = 128,
  OP_EVT_CHAR_VALUE = 129,
  OP_EVT_DISCONNECTED = 130,
  OP_EVT_CENTRAL_STATE_CHANGED = 131,
  OP_EVT_PERIPHERAL_STATE_CHANGED = 132,
  OP_EVT_READ_REQUEST = 133,
  OP_EVT_WRITE_REQUEST = 134,
  OP_EVT_SUBSCRIBED = 135,
  OP_EVT_UNSUBSCRIBED = 136,
  OP_EVT_READY_TO_UPDATE = 137,
  OP_EVT_CONNECTED = 138,
  OP_EVT_CONNECT_FAILED = 139,
  ST_OK = 0,
  ST_ERROR = 1
};

// CBOR major types (RFC 8949 3.1): uint, negative int, byte string, text, array, map
enum {
  CBOR_UINT = 0,
  CBOR_NEGINT = 1,
  CBOR_BYTES = 2,
  CBOR_TEXT = 3,
  CBOR_ARRAY = 4,
  CBOR_MAP = 5
};

typedef struct {
  uint8_t *buf;
  size_t cap;
  size_t pos;
  int overflow;
} writer;

static void w_head(writer *w, uint8_t major, uint64_t value) {
  uint8_t tag = (uint8_t)(major << 5);
  uint8_t tmp[9];
  size_t n = 0;
  if (value < 24) {
    tmp[n++] = (uint8_t)(tag | value);
  } else if (value < 0x100) {
    tmp[n++] = (uint8_t)(tag | 24);
    tmp[n++] = (uint8_t)value;
  } else if (value < 0x10000) {
    tmp[n++] = (uint8_t)(tag | 25);
    tmp[n++] = (uint8_t)(value >> 8);
    tmp[n++] = (uint8_t)value;
  } else if (value < 0x100000000ULL) {
    tmp[n++] = (uint8_t)(tag | 26);
    tmp[n++] = (uint8_t)(value >> 24);
    tmp[n++] = (uint8_t)(value >> 16);
    tmp[n++] = (uint8_t)(value >> 8);
    tmp[n++] = (uint8_t)value;
  } else {
    tmp[n++] = (uint8_t)(tag | 27);
    for (int s = 56; s >= 0; s -= 8)
      tmp[n++] = (uint8_t)(value >> s);
  }
  if (w->pos + n > w->cap) {
    w->overflow = 1;
    return;
  }
  memcpy(w->buf + w->pos, tmp, n);
  w->pos += n;
}

static void w_bytes(writer *w, uint8_t major, const uint8_t *data, size_t len) {
  w_head(w, major, len);
  if (w->overflow)
    return;
  if (w->pos + len > w->cap) {
    w->overflow = 1;
    return;
  }
  memcpy(w->buf + w->pos, data, len);
  w->pos += len;
}

// Write a uint key and a uint value.
static void w_kv_uint(writer *w, uint64_t key, uint64_t value) {
  w_head(w, CBOR_UINT, key);
  w_head(w, CBOR_UINT, value);
}

// Write a uint key and a byte-string value.
static void w_kv_bytes(writer *w, uint64_t key, const uint8_t *data, size_t len) {
  w_head(w, CBOR_UINT, key);
  w_bytes(w, CBOR_BYTES, data, len);
}

// Write a uint key and a text-string value.
static void w_kv_text(writer *w, uint64_t key, const char *data, size_t len) {
  w_head(w, CBOR_UINT, key);
  w_bytes(w, CBOR_TEXT, (const uint8_t *)data, len);
}

// Write a uint key and a definite-length array of text strings.
static void w_kv_text_array(writer *w, uint64_t key, const char *const *items, const size_t *lens,
                            size_t count) {
  w_head(w, CBOR_UINT, key);
  w_head(w, CBOR_ARRAY, count);
  for (size_t i = 0; i < count; i++)
    w_bytes(w, CBOR_TEXT, (const uint8_t *)items[i], lens[i]);
}

// Write a uint key and a packed-uint byte string: a 2-byte big-endian count, then each value as 8
// big-endian bytes.
static void w_kv_packed_uints(writer *w, uint64_t key, const uint64_t *values, size_t count) {
  uint8_t blob[2 + SIMBLE_MAX_CHARACTERISTICS * 8];
  if (count > SIMBLE_MAX_CHARACTERISTICS) {
    w->overflow = 1;
    return;
  }
  size_t n = 0;
  blob[n++] = (uint8_t)(count >> 8);
  blob[n++] = (uint8_t)count;
  for (size_t i = 0; i < count; i++)
    for (int s = 56; s >= 0; s -= 8)
      blob[n++] = (uint8_t)(values[i] >> s);
  w_kv_bytes(w, key, blob, n);
}

int simble_encode_hello(const uint8_t *token, size_t token_len, uint64_t version,
                        const uint8_t *app_id, size_t app_id_len, const uint8_t *display_name,
                        size_t display_name_len, uint8_t *out, size_t cap) {
  int has_id = app_id && app_id_len > 0;
  int has_name = display_name && display_name_len > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 3 + has_id + has_name);
  w_kv_uint(&w, K_OP, OP_HELLO);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_uint(&w, K_VERSION, version);
  if (has_id)
    w_kv_text(&w, K_APP_ID, (const char *)app_id, app_id_len);
  if (has_name)
    w_kv_text(&w, K_DISPLAY_NAME, (const char *)display_name, display_name_len);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_command(uint64_t op, const uint8_t *token, size_t token_len, uint8_t *out,
                          size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 2);
  w_kv_uint(&w, K_OP, op);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_peripheral_command(uint64_t op, const uint8_t *token, size_t token_len,
                                     const uint8_t *peripheral_id, size_t peripheral_len,
                                     uint8_t *out, size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 3);
  w_kv_uint(&w, K_OP, op);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_scan_start(const uint8_t *token, size_t token_len, const char *const *uuids,
                             const size_t *uuid_lens, size_t uuid_count, uint8_t *out, size_t cap) {
  int has_filter = uuids && uuid_count > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 2 + has_filter);
  w_kv_uint(&w, K_OP, OP_SCAN_START);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  if (has_filter)
    w_kv_text_array(&w, K_SERVICE_UUIDS, uuids, uuid_lens, uuid_count);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_discover_services(const uint8_t *token, size_t token_len,
                                    const uint8_t *peripheral_id, size_t peripheral_len,
                                    const char *const *uuids, const size_t *uuid_lens,
                                    size_t uuid_count, uint8_t *out, size_t cap) {
  int has_filter = uuids && uuid_count > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 3 + has_filter);
  w_kv_uint(&w, K_OP, OP_DISCOVER_SERVICES);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  if (has_filter)
    w_kv_text_array(&w, K_SERVICE_UUIDS, uuids, uuid_lens, uuid_count);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_discover_characteristics(const uint8_t *token, size_t token_len,
                                           const uint8_t *peripheral_id, size_t peripheral_len,
                                           const char *service, size_t service_len,
                                           const char *const *uuids, const size_t *uuid_lens,
                                           size_t uuid_count, uint8_t *out, size_t cap) {
  int has_filter = uuids && uuid_count > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 4 + has_filter);
  w_kv_uint(&w, K_OP, OP_DISCOVER_CHARACTERISTICS);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  if (has_filter)
    w_kv_text_array(&w, K_CHARACTERISTIC_UUIDS, uuids, uuid_lens, uuid_count);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_read_characteristic(const uint8_t *token, size_t token_len,
                                      const uint8_t *peripheral_id, size_t peripheral_len,
                                      const char *service, size_t service_len,
                                      const char *characteristic, size_t char_len, uint8_t *out,
                                      size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 5);
  w_kv_uint(&w, K_OP, OP_READ_CHARACTERISTIC);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  w_kv_text(&w, K_CHARACTERISTIC, characteristic, char_len);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_write_characteristic(const uint8_t *token, size_t token_len,
                                       const uint8_t *peripheral_id, size_t peripheral_len,
                                       const char *service, size_t service_len,
                                       const char *characteristic, size_t char_len,
                                       const uint8_t *value, size_t value_len,
                                       simble_write_type write_type, uint8_t *out, size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 7);
  w_kv_uint(&w, K_OP, OP_WRITE_CHARACTERISTIC);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  w_kv_text(&w, K_CHARACTERISTIC, characteristic, char_len);
  w_kv_bytes(&w, K_VALUE, value, value_len);
  w_kv_uint(&w, K_WRITE_TYPE, (uint64_t)write_type);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_set_notify(const uint8_t *token, size_t token_len, const uint8_t *peripheral_id,
                             size_t peripheral_len, const char *service, size_t service_len,
                             const char *characteristic, size_t char_len, int enabled, uint8_t *out,
                             size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 6);
  w_kv_uint(&w, K_OP, OP_SET_NOTIFY);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_PERIPHERAL, peripheral_id, peripheral_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  w_kv_text(&w, K_CHARACTERISTIC, characteristic, char_len);
  w_kv_uint(&w, K_NOTIFY, enabled ? 1 : 0);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_respond_read(const uint8_t *token, size_t token_len, uint64_t request_id,
                               const uint8_t *value, size_t value_len, uint64_t att_error,
                               uint8_t *out, size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 5);
  w_kv_uint(&w, K_OP, OP_RESPOND_READ);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_bytes(&w, K_VALUE, value, value_len);
  w_kv_uint(&w, K_REQUEST_ID, request_id);
  w_kv_uint(&w, K_ATT_ERROR, att_error);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_respond_write(const uint8_t *token, size_t token_len, uint64_t request_id,
                                uint64_t att_error, uint8_t *out, size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 4);
  w_kv_uint(&w, K_OP, OP_RESPOND_WRITE);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_uint(&w, K_REQUEST_ID, request_id);
  w_kv_uint(&w, K_ATT_ERROR, att_error);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_add_service(const uint8_t *token, size_t token_len, const char *service,
                              size_t service_len, int is_primary, const char *const *char_uuids,
                              const size_t *char_uuid_lens, const uint64_t *properties,
                              const uint64_t *permissions, size_t char_count, uint8_t *out,
                              size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 7);
  w_kv_uint(&w, K_OP, OP_ADD_SERVICE);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  w_kv_packed_uints(&w, K_CHAR_PROPERTIES, properties, char_count);
  w_kv_packed_uints(&w, K_ATT_PERMISSIONS, permissions, char_count);
  w_kv_uint(&w, K_IS_PRIMARY, is_primary ? 1 : 0);
  w_kv_text_array(&w, K_CHARACTERISTIC_UUIDS, char_uuids, char_uuid_lens, char_count);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_remove_service(const uint8_t *token, size_t token_len, const char *service,
                                 size_t service_len, uint8_t *out, size_t cap) {
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 3);
  w_kv_uint(&w, K_OP, OP_REMOVE_SERVICE);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_start_advertising(const uint8_t *token, size_t token_len, const char *local_name,
                                    size_t local_name_len, const char *const *uuids,
                                    const size_t *uuid_lens, size_t uuid_count, uint8_t *out,
                                    size_t cap) {
  int has_name = local_name && local_name_len > 0;
  int has_uuids = uuids && uuid_count > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 2 + has_name + has_uuids);
  w_kv_uint(&w, K_OP, OP_START_ADVERTISING);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  if (has_name)
    w_kv_text(&w, K_LOCAL_NAME, local_name, local_name_len);
  if (has_uuids)
    w_kv_text_array(&w, K_ADV_SERVICE_UUIDS, uuids, uuid_lens, uuid_count);
  return w.overflow ? -1 : (int)w.pos;
}

int simble_encode_update_value(const uint8_t *token, size_t token_len, const char *service,
                               size_t service_len, const char *characteristic, size_t char_len,
                               const uint8_t *value, size_t value_len, const uint8_t *central_id,
                               size_t central_len, uint8_t *out, size_t cap) {
  int has_central = central_id && central_len > 0;
  writer w = {out, cap, 0, 0};
  w_head(&w, CBOR_MAP, 5 + has_central);
  w_kv_uint(&w, K_OP, OP_UPDATE_VALUE);
  w_kv_bytes(&w, K_TOKEN, token, token_len);
  w_kv_text(&w, K_SERVICE, service, service_len);
  w_kv_text(&w, K_CHARACTERISTIC, characteristic, char_len);
  w_kv_bytes(&w, K_VALUE, value, value_len);
  if (has_central)
    w_kv_bytes(&w, K_CENTRAL, central_id, central_len);
  return w.overflow ? -1 : (int)w.pos;
}

typedef struct {
  const uint8_t *p;
  size_t len;
  size_t off;
} reader;

static simble_status r_head(reader *r, uint8_t *major, uint64_t *arg) {
  if (r->off >= r->len)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t b = r->p[r->off++];
  *major = b >> 5;
  uint8_t info = b & 0x1F;
  if (info < 24) {
    *arg = info;
    return SIMBLE_OK;
  }
  size_t n;
  uint64_t min;
  if (info == 24) {
    n = 1;
    min = 24;
  } else if (info == 25) {
    n = 2;
    min = 0x100;
  } else if (info == 26) {
    n = 4;
    min = 0x10000;
  } else if (info == 27) {
    n = 8;
    min = 0x100000000ULL;
  } else {
    return SIMBLE_ERR_MALFORMED;
  }
  if (n > r->len - r->off)
    return SIMBLE_ERR_TRUNCATED;
  uint64_t v = 0;
  for (size_t i = 0; i < n; i++)
    v = (v << 8) | r->p[r->off++];
  if (v < min)
    return SIMBLE_ERR_MALFORMED; // reject non-shortest-form (canonical)
  *arg = v;
  return SIMBLE_OK;
}

// One decoded map entry: a key and a value that is an int, a byte/text span, or an array span.
// For an array the span points at the array's encoded elements and uintval holds the element count;
// the decoder walks the span lazily only when a field reads the array.
typedef struct {
  uint64_t key;
  uint8_t major;
  uint64_t uintval;
  const uint8_t *span;
  size_t span_len;
} entry;

// Skip one CBOR value (uint, negint, byte/text string), advancing the reader. Arrays are not
// nested inside our arrays, so a single level of value-skipping covers every element.
static simble_status r_skip_value(reader *r) {
  uint8_t m;
  uint64_t a;
  simble_status st = r_head(r, &m, &a);
  if (st != SIMBLE_OK)
    return st;
  if (m == CBOR_UINT || m == CBOR_NEGINT)
    return SIMBLE_OK;
  if (m == CBOR_BYTES || m == CBOR_TEXT) {
    if (a > r->len - r->off)
      return SIMBLE_ERR_TRUNCATED;
    r->off += (size_t)a;
    return SIMBLE_OK;
  }
  return SIMBLE_ERR_TYPE;
}

static simble_status r_map(reader *r, entry *entries, size_t max, size_t *count) {
  uint8_t major;
  uint64_t n;
  simble_status st = r_head(r, &major, &n);
  if (st != SIMBLE_OK)
    return st;
  if (major != CBOR_MAP)
    return SIMBLE_ERR_TYPE;
  if (n > max)
    return SIMBLE_ERR_BUFFER;
  for (uint64_t i = 0; i < n; i++) {
    uint8_t km;
    uint64_t kv;
    st = r_head(r, &km, &kv);
    if (st != SIMBLE_OK)
      return st;
    if (km != CBOR_UINT)
      return SIMBLE_ERR_TYPE; // keys are uints
    for (uint64_t j = 0; j < i; j++) {
      if (entries[j].key == kv)
        return SIMBLE_ERR_MALFORMED; // reject duplicate key
    }
    uint8_t vm;
    uint64_t va;
    st = r_head(r, &vm, &va);
    if (st != SIMBLE_OK)
      return st;
    entry *e = &entries[i];
    e->key = kv;
    e->major = vm;
    if (vm == CBOR_UINT || vm == CBOR_NEGINT) {
      e->uintval = va;
      e->span = NULL;
      e->span_len = 0;
    } else if (vm == CBOR_BYTES || vm == CBOR_TEXT) {
      // Subtraction form: r->off + va would wrap for a hostile 64-bit length and defeat the
      // bound. r->off <= r->len is a reader invariant.
      if (va > r->len - r->off)
        return SIMBLE_ERR_TRUNCATED;
      e->span = r->p + r->off;
      e->span_len = (size_t)va;
      r->off += (size_t)va;
    } else if (vm == CBOR_ARRAY) {
      // Record the count and the span over the elements; skip each element to advance the reader.
      e->uintval = va;
      e->span = r->p + r->off;
      size_t start = r->off;
      for (uint64_t k = 0; k < va; k++) {
        st = r_skip_value(r);
        if (st != SIMBLE_OK)
          return st;
      }
      e->span_len = r->off - start;
    } else {
      return SIMBLE_ERR_TYPE;
    }
  }
  *count = (size_t)n;
  return r->off == r->len ? SIMBLE_OK : SIMBLE_ERR_MALFORMED;
}

static const entry *find(const entry *entries, size_t count, uint64_t key) {
  for (size_t i = 0; i < count; i++)
    if (entries[i].key == key)
      return &entries[i];
  return NULL;
}

static simble_status copy_bytes(const entry *e, uint8_t *dst, size_t cap, size_t *out_len) {
  if (!e || e->major != CBOR_BYTES)
    return SIMBLE_ERR_MISSING;
  if (e->span_len > cap)
    return SIMBLE_ERR_BUFFER;
  memcpy(dst, e->span, e->span_len);
  *out_len = e->span_len;
  return SIMBLE_OK;
}

// Copy a text span into a NUL-terminated fixed buffer, requiring room for the terminator.
static simble_status copy_text(const entry *e, char *dst, size_t cap) {
  if (!e || e->major != CBOR_TEXT)
    return SIMBLE_ERR_MISSING;
  if (e->span_len >= cap)
    return SIMBLE_ERR_BUFFER;
  memcpy(dst, e->span, e->span_len);
  dst[e->span_len] = '\0';
  return SIMBLE_OK;
}

// Copy an array of text strings into fixed NUL-terminated UUID buffers. The entry's span covers the
// array's encoded elements (recorded by r_map) and its uintval is the element count; this re-walks
// the span as text strings. An array longer than SIMBLE_MAX_UUIDS or a UUID longer than its buffer
// fails with SIMBLE_ERR_BUFFER. The discover responses carry the discovered UUIDs this way.
static simble_status copy_text_array(const entry *e, char uuids[][SIMBLE_UUID_CAP], size_t cap,
                                     size_t *out_count) {
  if (!e || e->major != CBOR_ARRAY)
    return SIMBLE_ERR_MISSING;
  if (e->uintval > cap)
    return SIMBLE_ERR_BUFFER;
  reader r = {e->span, e->span_len, 0};
  for (uint64_t i = 0; i < e->uintval; i++) {
    uint8_t m;
    uint64_t a;
    simble_status st = r_head(&r, &m, &a);
    if (st != SIMBLE_OK)
      return st;
    if (m != CBOR_TEXT)
      return SIMBLE_ERR_TYPE;
    if (a > r.len - r.off)
      return SIMBLE_ERR_TRUNCATED;
    if (a >= SIMBLE_UUID_CAP)
      return SIMBLE_ERR_BUFFER;
    memcpy(uuids[i], r.p + r.off, (size_t)a);
    uuids[i][a] = '\0';
    r.off += (size_t)a;
  }
  *out_count = (size_t)e->uintval;
  return SIMBLE_OK;
}

// Read a bounded signed code from an int entry (key 10 / RSSI / TX power). An out-of-range or
// missing value yields 0 and clears the presence flag, so a hostile code never traps.
static int64_t read_int(const entry *e, int *present) {
  if (e && e->major == CBOR_NEGINT && e->uintval < INT64_MAX) {
    if (present)
      *present = 1;
    return -(int64_t)(e->uintval) - 1; // CBOR negint n encodes -1 - n
  }
  if (e && e->major == CBOR_UINT && e->uintval <= (uint64_t)INT64_MAX) {
    if (present)
      *present = 1;
    return (int64_t)e->uintval;
  }
  if (present)
    *present = 0;
  return 0;
}

simble_status simble_decode_response(const uint8_t *payload, size_t len, simble_response *out) {
  reader r = {payload, len, 0};
  entry entries[8];
  size_t count = 0;
  simble_status st = r_map(&r, entries, 8, &count);
  if (st != SIMBLE_OK)
    return st;

  const entry *status = find(entries, count, K_STATUS);
  const entry *op = find(entries, count, K_OP);
  if (!status || status->major != CBOR_UINT || !op || op->major != CBOR_UINT) {
    return SIMBLE_ERR_MISSING;
  }
  memset(out, 0, sizeof(*out));
  out->resp_op = op->uintval;

  if (status->uintval == ST_ERROR) {
    out->kind = SIMBLE_RESP_ERROR;
    out->error_code = read_int(find(entries, count, K_ERR_CODE), NULL);
    const entry *msg = find(entries, count, K_ERR);
    size_t n = 0;
    if (msg && msg->major == CBOR_TEXT) {
      n = msg->span_len < sizeof(out->error) - 1 ? msg->span_len : sizeof(out->error) - 1;
      memcpy(out->error, msg->span, n);
    }
    out->error[n] = '\0';
    return SIMBLE_OK;
  }
  if (status->uintval != ST_OK)
    return SIMBLE_ERR_STATUS;

  switch (op->uintval) {
  case OP_HELLO: {
    out->kind = SIMBLE_RESP_HELLO;
    const entry *ver = find(entries, count, K_VERSION);
    out->version = (ver && ver->major == CBOR_UINT) ? ver->uintval : 0;
    return SIMBLE_OK;
  }
  case OP_CENTRAL_STATE: {
    out->kind = SIMBLE_RESP_CENTRAL_STATE;
    const entry *ms = find(entries, count, K_MANAGER_STATE);
    if (!ms || ms->major != CBOR_UINT)
      return SIMBLE_ERR_MISSING;
    out->manager_state = ms->uintval;
    return SIMBLE_OK;
  }
  case OP_SCAN_START:
  case OP_SCAN_STOP:
  case OP_WRITE_CHARACTERISTIC:
  case OP_START_ADVERTISING:
  case OP_STOP_ADVERTISING:
  case OP_RESPOND_READ:
  case OP_RESPOND_WRITE:
  case OP_UPDATE_VALUE:
    out->kind = SIMBLE_RESP_CONFIRMED;
    return SIMBLE_OK;
  case OP_CONNECT:
  case OP_DISCONNECT:
    out->kind = SIMBLE_RESP_PERIPHERAL;
    return copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                      &out->peripheral_len);
  case OP_READ_RSSI: {
    out->kind = SIMBLE_RESP_RSSI;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    const entry *rssi = find(entries, count, K_RSSI);
    int present = 0;
    out->rssi = read_int(rssi, &present);
    return present ? SIMBLE_OK : SIMBLE_ERR_MISSING;
  }
  case OP_PERIPHERAL_STATE: {
    out->kind = SIMBLE_RESP_PERIPHERAL_STATE;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    const entry *ms = find(entries, count, K_MANAGER_STATE);
    if (!ms || ms->major != CBOR_UINT)
      return SIMBLE_ERR_MISSING;
    out->manager_state = ms->uintval;
    return SIMBLE_OK;
  }
  case OP_READ_CHARACTERISTIC: {
    out->kind = SIMBLE_RESP_CHAR_VALUE;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_CHARACTERISTIC), out->characteristic,
                   sizeof(out->characteristic));
    if (st != SIMBLE_OK)
      return st;
    return copy_bytes(find(entries, count, K_VALUE), out->value, sizeof(out->value),
                      &out->value_len);
  }
  case OP_SET_NOTIFY: {
    out->kind = SIMBLE_RESP_NOTIFY_STATE;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_CHARACTERISTIC), out->characteristic,
                   sizeof(out->characteristic));
    if (st != SIMBLE_OK)
      return st;
    const entry *flag = find(entries, count, K_NOTIFY);
    if (!flag || flag->major != CBOR_UINT)
      return SIMBLE_ERR_MISSING;
    out->notify = flag->uintval != 0 ? 1 : 0;
    return SIMBLE_OK;
  }
  case OP_DISCOVER_SERVICES: {
    out->kind = SIMBLE_RESP_SERVICES_DISCOVERED;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    return copy_text_array(find(entries, count, K_SERVICE_UUIDS), out->uuids, SIMBLE_MAX_UUIDS,
                           &out->uuid_count);
  }
  case OP_DISCOVER_CHARACTERISTICS: {
    out->kind = SIMBLE_RESP_CHARS_DISCOVERED;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    return copy_text_array(find(entries, count, K_CHARACTERISTIC_UUIDS), out->uuids,
                           SIMBLE_MAX_UUIDS, &out->uuid_count);
  }
  case OP_ADD_SERVICE:
  case OP_REMOVE_SERVICE:
    out->kind = SIMBLE_RESP_SERVICE;
    return copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
  default:
    return SIMBLE_ERR_OPCODE;
  }
}

simble_status simble_decode_event(const uint8_t *payload, size_t len, simble_event *out) {
  reader r = {payload, len, 0};
  entry entries[8];
  size_t count = 0;
  simble_status st = r_map(&r, entries, 8, &count);
  if (st != SIMBLE_OK)
    return st;

  const entry *op = find(entries, count, K_OP);
  if (!op || op->major != CBOR_UINT)
    return SIMBLE_ERR_MISSING;
  memset(out, 0, sizeof(*out));
  out->evt_op = op->uintval;

  switch (op->uintval) {
  case OP_EVT_DISCOVERED: {
    out->kind = SIMBLE_EVT_DISCOVERED;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    int present = 0;
    out->rssi = read_int(find(entries, count, K_RSSI), &present);
    if (!present)
      return SIMBLE_ERR_MISSING;
    const entry *name = find(entries, count, K_LOCAL_NAME);
    if (name && name->major == CBOR_TEXT) {
      st = copy_text(name, out->local_name, sizeof(out->local_name));
      if (st != SIMBLE_OK)
        return st;
      out->has_local_name = 1;
    }
    out->tx_power = read_int(find(entries, count, K_TX_POWER), &out->has_tx_power);
    const entry *mfg = find(entries, count, K_MFG_DATA);
    if (mfg && mfg->major == CBOR_BYTES) {
      st = copy_bytes(mfg, out->mfg_data, sizeof(out->mfg_data), &out->mfg_data_len);
      if (st != SIMBLE_OK)
        return st;
      out->has_mfg_data = 1;
    }
    return SIMBLE_OK;
  }
  case OP_EVT_CHAR_VALUE: {
    out->kind = SIMBLE_EVT_CHAR_VALUE;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_CHARACTERISTIC), out->characteristic,
                   sizeof(out->characteristic));
    if (st != SIMBLE_OK)
      return st;
    return copy_bytes(find(entries, count, K_VALUE), out->value, sizeof(out->value),
                      &out->value_len);
  }
  case OP_EVT_DISCONNECTED: {
    out->kind = SIMBLE_EVT_DISCONNECTED;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    out->error_code = read_int(find(entries, count, K_ERR_CODE), &out->has_error_code);
    return SIMBLE_OK;
  }
  case OP_EVT_CONNECTED: {
    out->kind = SIMBLE_EVT_CONNECTED;
    return copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                      &out->peripheral_len);
  }
  case OP_EVT_CONNECT_FAILED: {
    out->kind = SIMBLE_EVT_CONNECT_FAILED;
    st = copy_bytes(find(entries, count, K_PERIPHERAL), out->peripheral, sizeof(out->peripheral),
                    &out->peripheral_len);
    if (st != SIMBLE_OK)
      return st;
    out->error_code = read_int(find(entries, count, K_ERR_CODE), &out->has_error_code);
    return SIMBLE_OK;
  }
  case OP_EVT_CENTRAL_STATE_CHANGED:
  case OP_EVT_PERIPHERAL_STATE_CHANGED: {
    out->kind = op->uintval == OP_EVT_CENTRAL_STATE_CHANGED ? SIMBLE_EVT_CENTRAL_STATE_CHANGED
                                                            : SIMBLE_EVT_PERIPHERAL_STATE_CHANGED;
    const entry *ms = find(entries, count, K_MANAGER_STATE);
    if (!ms || ms->major != CBOR_UINT)
      return SIMBLE_ERR_MISSING;
    out->manager_state = ms->uintval;
    return SIMBLE_OK;
  }
  case OP_EVT_READ_REQUEST:
  case OP_EVT_WRITE_REQUEST: {
    int is_write = op->uintval == OP_EVT_WRITE_REQUEST;
    out->kind = is_write ? SIMBLE_EVT_WRITE_REQUEST : SIMBLE_EVT_READ_REQUEST;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_CHARACTERISTIC), out->characteristic,
                   sizeof(out->characteristic));
    if (st != SIMBLE_OK)
      return st;
    const entry *req = find(entries, count, K_REQUEST_ID);
    const entry *off = find(entries, count, K_ATT_OFFSET);
    if (!req || req->major != CBOR_UINT || !off || off->major != CBOR_UINT) {
      return SIMBLE_ERR_MISSING;
    }
    out->request_id = req->uintval;
    out->att_offset = off->uintval;
    st = copy_bytes(find(entries, count, K_CENTRAL), out->central, sizeof(out->central),
                    &out->central_len);
    if (st != SIMBLE_OK)
      return st;
    if (is_write) {
      return copy_bytes(find(entries, count, K_VALUE), out->value, sizeof(out->value),
                        &out->value_len);
    }
    return SIMBLE_OK;
  }
  case OP_EVT_SUBSCRIBED:
  case OP_EVT_UNSUBSCRIBED: {
    int sub = op->uintval == OP_EVT_SUBSCRIBED;
    out->kind = sub ? SIMBLE_EVT_SUBSCRIBED : SIMBLE_EVT_UNSUBSCRIBED;
    st = copy_text(find(entries, count, K_SERVICE), out->service, sizeof(out->service));
    if (st != SIMBLE_OK)
      return st;
    st = copy_text(find(entries, count, K_CHARACTERISTIC), out->characteristic,
                   sizeof(out->characteristic));
    if (st != SIMBLE_OK)
      return st;
    st = copy_bytes(find(entries, count, K_CENTRAL), out->central, sizeof(out->central),
                    &out->central_len);
    if (st != SIMBLE_OK)
      return st;
    if (sub) {
      const entry *mtu = find(entries, count, K_MTU);
      if (!mtu || mtu->major != CBOR_UINT)
        return SIMBLE_ERR_MISSING;
      out->mtu = mtu->uintval;
    }
    return SIMBLE_OK;
  }
  case OP_EVT_READY_TO_UPDATE:
    out->kind = SIMBLE_EVT_READY_TO_UPDATE;
    return SIMBLE_OK;
  default:
    return SIMBLE_ERR_OPCODE;
  }
}
