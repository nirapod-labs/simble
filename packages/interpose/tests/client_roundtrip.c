/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file client_roundtrip.c
 * @brief Transport round-trip: the client frames a request and decodes a response and an event.
 *
 * @details
 * An in-test loopback echo, bound to an ephemeral port on 127.0.0.1, plays the helper: it reads
 * each request frame, confirms the capability token rides in it, and replies with a canonical
 * response built here. One connection also receives an event frame, so the client's event reader
 * is exercised. The transport reuses the simble_protocol C codec for the request encoding and the
 * response and event decoding; the canned replies are hand-built canonical CBOR, so the codec is
 * the thing under test, with no radio and no helper.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "client.h"
#include "simble_protocol.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg)                                                                           \
  do {                                                                                             \
    if (!(cond)) {                                                                                 \
      printf("FAIL: %s\n", msg);                                                                   \
      fails++;                                                                                     \
    }                                                                                              \
  } while (0)

// A canonical CBOR head: the major type in the top three bits, then the shortest-form argument.
static size_t put_head(uint8_t *out, uint8_t major, uint64_t value) {
  uint8_t tag = (uint8_t)(major << 5);
  if (value < 24) {
    out[0] = (uint8_t)(tag | value);
    return 1;
  }
  if (value < 0x100) {
    out[0] = (uint8_t)(tag | 24);
    out[1] = (uint8_t)value;
    return 2;
  }
  out[0] = (uint8_t)(tag | 25);
  out[1] = (uint8_t)(value >> 8);
  out[2] = (uint8_t)value;
  return 3;
}

static size_t put_kv_uint(uint8_t *out, uint64_t key, uint64_t value) {
  size_t n = put_head(out, 0, key);
  return n + put_head(out + n, 0, value);
}

static size_t put_kv_text(uint8_t *out, uint64_t key, const char *text) {
  size_t n = put_head(out, 0, key);
  size_t len = strlen(text);
  n += put_head(out + n, 3, len);
  memcpy(out + n, text, len);
  return n + len;
}

static size_t put_kv_bytes(uint8_t *out, uint64_t key, const uint8_t *bytes, size_t len) {
  size_t n = put_head(out, 0, key);
  n += put_head(out + n, 2, len);
  memcpy(out + n, bytes, len);
  return n + len;
}

static int write_all(int fd, const uint8_t *buf, size_t len) {
  size_t written = 0;
  while (written < len) {
    ssize_t n = send(fd, buf + written, len - written, 0);
    if (n <= 0)
      return -1;
    written += (size_t)n;
  }
  return 0;
}

static int read_all(int fd, uint8_t *buf, size_t len) {
  size_t got = 0;
  while (got < len) {
    ssize_t n = recv(fd, buf + got, len - got, 0);
    if (n <= 0)
      return -1;
    got += (size_t)n;
  }
  return 0;
}

// Send one payload as a 4-byte big-endian length-prefixed frame.
static int send_frame(int fd, const uint8_t *payload, size_t len) {
  uint8_t prefix[4] = {(uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8),
                       (uint8_t)len};
  if (write_all(fd, prefix, 4) != 0)
    return -1;
  return write_all(fd, payload, len);
}

// Read one request frame; confirm it carries the 32-byte token (key 7) and return its op (key 0).
static int read_request(int fd, uint64_t *op_out) {
  uint8_t prefix[4];
  if (read_all(fd, prefix, 4) != 0)
    return -1;
  uint32_t len = ((uint32_t)prefix[0] << 24) | ((uint32_t)prefix[1] << 16) |
                 ((uint32_t)prefix[2] << 8) | (uint32_t)prefix[3];
  if (len == 0 || len > 8192)
    return -1;
  uint8_t *buf = malloc(len);
  if (!buf)
    return -1;
  if (read_all(fd, buf, len) != 0) {
    free(buf);
    return -1;
  }
  // The first map entry is op: key 0 (byte 0xa? then 0x00) then the op uint. Read it directly.
  // buf[0] is the map head; buf[1] is key 0; buf[2..] is the op value head.
  uint64_t op = 0;
  if (len >= 3 && (buf[1] == 0x00)) {
    uint8_t info = buf[2] & 0x1F;
    if (info < 24) {
      op = info;
    } else if (info == 24 && len >= 4) {
      op = buf[3];
    }
  }
  // Confirm a 32-byte byte string for key 7 appears somewhere in the payload: 0x07 0x58 0x20.
  int token_ok = 0;
  for (uint32_t i = 0; i + 2 < len; i++) {
    if (buf[i] == 0x07 && buf[i + 1] == 0x58 && buf[i + 2] == 0x20) {
      token_ok = 1;
      break;
    }
  }
  free(buf);
  if (!token_ok)
    return -1;
  *op_out = op;
  return 0;
}

static const uint8_t kPeripheralId[] = {0x11, 0x22, 0x33, 0x44};

// Build the canonical response the helper would send for an op, returning its length.
static size_t build_response(uint64_t op, uint8_t *out) {
  size_t n = 0;
  switch (op) {
  case 1: // HELLO: { 0:1, 1:0, 8:1 }
    n += put_head(out + n, 5, 3);
    n += put_kv_uint(out + n, 0, 1);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_uint(out + n, 8, 1);
    return n;
  case 2: // CENTRAL_STATE: { 0:2, 1:0, 41:5 } (5 == poweredOn)
    n += put_head(out + n, 5, 3);
    n += put_kv_uint(out + n, 0, 2);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_uint(out + n, 41, 5);
    return n;
  case 3: // SCAN_START: { 0:3, 1:0 }
  case 4: // SCAN_STOP: { 0:4, 1:0 }
    n += put_head(out + n, 5, 2);
    n += put_kv_uint(out + n, 0, op);
    n += put_kv_uint(out + n, 1, 0);
    return n;
  case 5: // CONNECT: { 0:5, 1:0, 30:<id> }
  case 6: // DISCONNECT: { 0:6, 1:0, 30:<id> }
    n += put_head(out + n, 5, 3);
    n += put_kv_uint(out + n, 0, op);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_bytes(out + n, 30, kPeripheralId, sizeof(kPeripheralId));
    return n;
  case 9: // READ_CHARACTERISTIC: { 0:9, 1:0, 30:<id>, 31:svc, 32:chr, 33:val }
    n += put_head(out + n, 5, 6);
    n += put_kv_uint(out + n, 0, 9);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_bytes(out + n, 30, kPeripheralId, sizeof(kPeripheralId));
    n += put_kv_text(out + n, 31, "180D");
    n += put_kv_text(out + n, 32, "2A37");
    {
      const uint8_t val[] = {0x48, 0x69};
      n += put_kv_bytes(out + n, 33, val, sizeof(val));
    }
    return n;
  case 10: // WRITE_CHARACTERISTIC: { 0:10, 1:0 }
    n += put_head(out + n, 5, 2);
    n += put_kv_uint(out + n, 0, 10);
    n += put_kv_uint(out + n, 1, 0);
    return n;
  case 11: // SET_NOTIFY: { 0:11, 1:0, 30:<id>, 31:svc, 32:chr, 40:1 }
    n += put_head(out + n, 5, 6);
    n += put_kv_uint(out + n, 0, 11);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_bytes(out + n, 30, kPeripheralId, sizeof(kPeripheralId));
    n += put_kv_text(out + n, 31, "180D");
    n += put_kv_text(out + n, 32, "2A37");
    n += put_kv_uint(out + n, 40, 1);
    return n;
  case 12: // READ_RSSI: { 0:12, 1:0, 30:<id>, 34:-50 }
    n += put_head(out + n, 5, 4);
    n += put_kv_uint(out + n, 0, 12);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_bytes(out + n, 30, kPeripheralId, sizeof(kPeripheralId));
    n += put_head(out + n, 0, 34);
    n += put_head(out + n, 1, 49); // CBOR negint 49 encodes -50
    return n;
  case 14: // ADD_SERVICE: { 0:14, 1:0, 31:svc }
  case 15: // REMOVE_SERVICE: { 0:15, 1:0, 31:svc }
    n += put_head(out + n, 5, 3);
    n += put_kv_uint(out + n, 0, op);
    n += put_kv_uint(out + n, 1, 0);
    n += put_kv_text(out + n, 31, "180D");
    return n;
  case 16: // START_ADVERTISING: { 0:16, 1:0 }
  case 17: // STOP_ADVERTISING: { 0:17, 1:0 }
  case 18: // RESPOND_READ: { 0:18, 1:0 }
  case 19: // RESPOND_WRITE: { 0:19, 1:0 }
  case 20: // UPDATE_VALUE: { 0:20, 1:0 }
    n += put_head(out + n, 5, 2);
    n += put_kv_uint(out + n, 0, op);
    n += put_kv_uint(out + n, 1, 0);
    return n;
  default:
    return 0;
  }
}

// A DISCOVERED event: { 0:128, 30:<id>, 34:-40 }.
static size_t build_discovered_event(uint8_t *out) {
  size_t n = 0;
  n += put_head(out + n, 5, 3);
  n += put_kv_uint(out + n, 0, 128);
  n += put_kv_bytes(out + n, 30, kPeripheralId, sizeof(kPeripheralId));
  n += put_head(out + n, 0, 34);
  n += put_head(out + n, 1, 39); // CBOR negint 39 encodes -40
  return n;
}

typedef struct {
  uint16_t port;
  int ready;
  pthread_mutex_t lock;
  pthread_cond_t cond;
} server_ctx;

// The echo server: accept connections, answer each request, and on the last connection send an
// event frame before closing.
static void *server_thread(void *arg) {
  server_ctx *ctx = arg;
  int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  int reuse = 1;
  setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = 0;
  addr.sin_addr.s_addr = inet_addr("127.0.0.1");
  bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr));
  listen(listen_fd, 16);
  socklen_t alen = sizeof(addr);
  getsockname(listen_fd, (struct sockaddr *)&addr, &alen);

  pthread_mutex_lock(&ctx->lock);
  ctx->port = ntohs(addr.sin_port);
  ctx->ready = 1;
  pthread_cond_signal(&ctx->cond);
  pthread_mutex_unlock(&ctx->lock);

  // Serve one connection per directed request, then one connection that carries an event.
  for (int i = 0; i < 17; i++) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0)
      break;
    uint64_t op = 0;
    if (read_request(fd, &op) == 0) {
      uint8_t resp[256];
      size_t len = build_response(op, resp);
      if (len)
        send_frame(fd, resp, len);
    }
    close(fd);
  }
  // The event connection: the client opens it, the server pushes one event frame.
  int evt_fd = accept(listen_fd, NULL, NULL);
  if (evt_fd >= 0) {
    uint8_t evt[64];
    size_t len = build_discovered_event(evt);
    send_frame(evt_fd, evt, len);
    close(evt_fd);
  }
  close(listen_fd);
  return NULL;
}

int main(void) {
  server_ctx ctx = {0, 0, PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER};
  pthread_t thread;
  pthread_create(&thread, NULL, server_thread, &ctx);

  pthread_mutex_lock(&ctx.lock);
  while (!ctx.ready)
    pthread_cond_wait(&ctx.cond, &ctx.lock);
  uint16_t port = ctx.port;
  pthread_mutex_unlock(&ctx.lock);

  char port_str[16];
  snprintf(port_str, sizeof(port_str), "%u", port);
  setenv("SIMBLE_PORT", port_str, 1);
  setenv("SIMBLE_TOKEN", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", 1);

  simble_response resp;
  CHECK(simble_client_hello(SIMBLE_PROTOCOL_VERSION, NULL, 0, NULL, 0, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_HELLO && resp.version == 1,
        "hello negotiates v1");

  CHECK(simble_client_central_state(&resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CENTRAL_STATE &&
            resp.manager_state == 5,
        "central state is poweredOn");

  const char *uuid = "180D";
  const size_t uuid_len = 4;
  CHECK(simble_client_scan_start(&uuid, &uuid_len, 1, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED,
        "scan start confirmed");
  CHECK(simble_client_scan_stop(&resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED,
        "scan stop confirmed");

  CHECK(simble_client_connect(kPeripheralId, sizeof(kPeripheralId), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_PERIPHERAL && resp.peripheral_len == sizeof(kPeripheralId) &&
            memcmp(resp.peripheral, kPeripheralId, sizeof(kPeripheralId)) == 0,
        "connect echoes the peripheral id");

  CHECK(simble_client_read_characteristic(kPeripheralId, sizeof(kPeripheralId), "180D", 4, "2A37",
                                          4, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CHAR_VALUE && resp.value_len == 2 && resp.value[0] == 0x48 &&
            resp.value[1] == 0x69,
        "read characteristic returns the value");

  const uint8_t wv[] = {0x01};
  CHECK(simble_client_write_characteristic(kPeripheralId, sizeof(kPeripheralId), "180D", 4, "2A37",
                                           4, wv, sizeof(wv), SIMBLE_WRITE_WITH_RESPONSE,
                                           &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED,
        "write characteristic confirmed");

  CHECK(simble_client_set_notify(kPeripheralId, sizeof(kPeripheralId), "180D", 4, "2A37", 4, 1,
                                 &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_NOTIFY_STATE && resp.notify == 1,
        "set notify enabled");

  CHECK(simble_client_read_rssi(kPeripheralId, sizeof(kPeripheralId), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_RSSI && resp.rssi == -50,
        "read rssi returns the signal strength");

  CHECK(simble_client_disconnect(kPeripheralId, sizeof(kPeripheralId), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_PERIPHERAL,
        "disconnect echoes the peripheral id");

  // The peripheral one-shot requests: publish, advertise, respond, notify.
  const char *charUUID = "2A37";
  const size_t charLen = 4;
  const uint64_t props[] = {0x02}; // CBCharacteristicPropertyRead
  const uint64_t perms[] = {0x01}; // CBAttributePermissionsReadable
  CHECK(simble_client_add_service("180D", 4, 1, &charUUID, &charLen, props, perms, 1, &resp) ==
            SIMBLE_OK && resp.kind == SIMBLE_RESP_SERVICE,
        "add service confirmed");
  CHECK(simble_client_remove_service("180D", 4, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_SERVICE,
        "remove service confirmed");

  const char *advUUID = "180D";
  const size_t advLen = 4;
  CHECK(simble_client_start_advertising("Sim", 3, &advUUID, &advLen, 1, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED,
        "start advertising confirmed");
  CHECK(simble_client_stop_advertising(&resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED,
        "stop advertising confirmed");

  const uint8_t readValue[] = {0x42};
  CHECK(simble_client_respond_read(7, readValue, sizeof(readValue), 0, &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED,
        "respond read confirmed");
  CHECK(simble_client_respond_write(8, 0, &resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED,
        "respond write confirmed");

  const uint8_t notifyValue[] = {0x48, 0x69};
  CHECK(simble_client_update_value("180D", 4, "2A37", 4, notifyValue, sizeof(notifyValue), NULL, 0,
                                   &resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED,
        "update value confirmed");

  // The event stream: open a connection and read one DISCOVERED event.
  simble_conn conn;
  CHECK(simble_client_open(&conn) == SIMBLE_OK, "open the event connection");
  simble_event event;
  CHECK(simble_client_read_event(&conn, &event) == SIMBLE_OK &&
            event.kind == SIMBLE_EVT_DISCOVERED && event.rssi == -40 &&
            event.peripheral_len == sizeof(kPeripheralId),
        "read a discovered event");
  simble_client_close(&conn);

  pthread_join(thread, NULL);
  printf(fails ? "CLIENT ROUNDTRIP: %d failure(s)\n" : "CLIENT ROUNDTRIP: ok\n", fails);
  return fails ? 1 : 0;
}
