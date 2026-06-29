/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file client.c
 * @brief Loopback client implementation: connect, frame, send, read, decode.
 *
 * @see client.h for the API documentation.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include "client.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int connect_helper(void) {
  const char *env = getenv("SIMBLE_PORT");
  if (!env)
    return -1;
  char *end = NULL;
  long port = strtol(env, &end, 10);
  if (end == env || *end != '\0' || port <= 0 || port > 65535)
    return -1;

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = inet_addr("127.0.0.1");

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
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
  size_t read_count = 0;
  while (read_count < len) {
    ssize_t n = recv(fd, buf + read_count, len - read_count, 0);
    if (n <= 0)
      return -1;
    read_count += (size_t)n;
  }
  return 0;
}

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

// Decode the 32-byte capability token from SIMBLE_TOKEN (64 hex chars). Returns 0 on
// success, -1 when the variable is missing or malformed.
static int read_token(uint8_t out[32]) {
  const char *hex = getenv("SIMBLE_TOKEN");
  if (!hex || strlen(hex) != 64)
    return -1;
  for (size_t i = 0; i < 32; i++) {
    int hi = hex_nibble(hex[i * 2]);
    int lo = hex_nibble(hex[(i * 2) + 1]);
    if (hi < 0 || lo < 0)
      return -1;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return 0;
}

// Read one length-prefixed frame's payload into a caller buffer.
static simble_status read_frame(int fd, uint8_t *resp, size_t resp_cap, size_t *resp_len) {
  uint8_t prefix[4];
  if (read_all(fd, prefix, 4) != 0)
    return SIMBLE_ERR_TRUNCATED;
  long payload_len = simble_payload_length(prefix);
  if (payload_len < 0)
    return SIMBLE_ERR_MALFORMED;
  if ((size_t)payload_len > resp_cap)
    return SIMBLE_ERR_BUFFER;
  if (read_all(fd, resp, (size_t)payload_len) != 0)
    return SIMBLE_ERR_TRUNCATED;
  *resp_len = (size_t)payload_len;
  return SIMBLE_OK;
}

// Send one framed request and read one framed reply payload into a caller buffer, undecoded.
static simble_status do_request_raw(const uint8_t *payload, int payload_len, uint8_t *resp,
                                    size_t resp_cap, size_t *resp_len) {
  if (payload_len < 0)
    return SIMBLE_ERR_BUFFER;

  int fd = connect_helper();
  if (fd < 0)
    return SIMBLE_ERR_TRUNCATED;

  uint8_t frame[8192];
  int frame_len = simble_frame(payload, (size_t)payload_len, frame, sizeof(frame));
  if (frame_len < 0 || write_all(fd, frame, (size_t)frame_len) != 0) {
    close(fd);
    return SIMBLE_ERR_BUFFER;
  }
  simble_status st = read_frame(fd, resp, resp_cap, resp_len);
  close(fd);
  return st;
}

static simble_status do_request(const uint8_t *payload, int payload_len, simble_response *out) {
  uint8_t response[4096];
  size_t response_len = 0;
  simble_status st =
      do_request_raw(payload, payload_len, response, sizeof(response), &response_len);
  if (st != SIMBLE_OK)
    return st;
  return simble_decode_response(response, response_len, out);
}

simble_status simble_client_hello(uint64_t version, const uint8_t *app_id, size_t app_id_len,
                                  const uint8_t *display_name, size_t display_name_len,
                                  simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  int n = simble_encode_hello(token, sizeof(token), version, app_id, app_id_len, display_name,
                              display_name_len, payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_central_state(simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[64];
  // CENTRAL_STATE is op 2, a token-only command.
  int n = simble_encode_command(2, token, sizeof(token), payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_scan_start(const char *const *uuids, const size_t *uuid_lens,
                                       size_t uuid_count, simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[1024];
  int n = simble_encode_scan_start(token, sizeof(token), uuids, uuid_lens, uuid_count, payload,
                                   sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_scan_stop(simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[64];
  // SCAN_STOP is op 4, a token-only command.
  int n = simble_encode_command(4, token, sizeof(token), payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_connect(const uint8_t *peripheral_id, size_t peripheral_len,
                                    simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  // CONNECT is op 5.
  int n = simble_encode_peripheral_command(5, token, sizeof(token), peripheral_id, peripheral_len,
                                           payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_disconnect(const uint8_t *peripheral_id, size_t peripheral_len,
                                       simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  // DISCONNECT is op 6.
  int n = simble_encode_peripheral_command(6, token, sizeof(token), peripheral_id, peripheral_len,
                                           payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_discover_services(const uint8_t *peripheral_id, size_t peripheral_len,
                                              const char *const *uuids, const size_t *uuid_lens,
                                              size_t uuid_count, simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[1024];
  int n = simble_encode_discover_services(token, sizeof(token), peripheral_id, peripheral_len,
                                          uuids, uuid_lens, uuid_count, payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_discover_characteristics(const uint8_t *peripheral_id,
                                                     size_t peripheral_len, const char *service,
                                                     size_t service_len, const char *const *uuids,
                                                     const size_t *uuid_lens, size_t uuid_count,
                                                     simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[1024];
  int n = simble_encode_discover_characteristics(token, sizeof(token), peripheral_id,
                                                 peripheral_len, service, service_len, uuids,
                                                 uuid_lens, uuid_count, payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_read_characteristic(const uint8_t *peripheral_id, size_t peripheral_len,
                                                const char *service, size_t service_len,
                                                const char *characteristic, size_t char_len,
                                                simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[512];
  int n = simble_encode_read_characteristic(token, sizeof(token), peripheral_id, peripheral_len,
                                            service, service_len, characteristic, char_len, payload,
                                            sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_write_characteristic(const uint8_t *peripheral_id,
                                                 size_t peripheral_len, const char *service,
                                                 size_t service_len, const char *characteristic,
                                                 size_t char_len, const uint8_t *value,
                                                 size_t value_len, simble_write_type write_type,
                                                 simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[2048];
  int n = simble_encode_write_characteristic(token, sizeof(token), peripheral_id, peripheral_len,
                                             service, service_len, characteristic, char_len, value,
                                             value_len, write_type, payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_set_notify(const uint8_t *peripheral_id, size_t peripheral_len,
                                       const char *service, size_t service_len,
                                       const char *characteristic, size_t char_len, int enabled,
                                       simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[512];
  int n = simble_encode_set_notify(token, sizeof(token), peripheral_id, peripheral_len, service,
                                   service_len, characteristic, char_len, enabled, payload,
                                   sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_read_rssi(const uint8_t *peripheral_id, size_t peripheral_len,
                                      simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  // READ_RSSI is op 12.
  int n = simble_encode_peripheral_command(12, token, sizeof(token), peripheral_id, peripheral_len,
                                           payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_add_service(const char *service, size_t service_len, int is_primary,
                                        const char *const *char_uuids, const size_t *char_uuid_lens,
                                        const uint64_t *properties, const uint64_t *permissions,
                                        size_t char_count, simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[4096];
  int n = simble_encode_add_service(token, sizeof(token), service, service_len, is_primary,
                                    char_uuids, char_uuid_lens, properties, permissions, char_count,
                                    payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_remove_service(const char *service, size_t service_len,
                                           simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  int n = simble_encode_remove_service(token, sizeof(token), service, service_len, payload,
                                       sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_start_advertising(const char *local_name, size_t local_name_len,
                                              const char *const *uuids, const size_t *uuid_lens,
                                              size_t uuid_count, simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[1024];
  int n = simble_encode_start_advertising(token, sizeof(token), local_name, local_name_len, uuids,
                                          uuid_lens, uuid_count, payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_stop_advertising(simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[64];
  // STOP_ADVERTISING is op 17, a token-only command.
  int n = simble_encode_command(17, token, sizeof(token), payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_respond_read(uint64_t request_id, const uint8_t *value, size_t value_len,
                                         uint64_t att_error, simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[2048];
  int n = simble_encode_respond_read(token, sizeof(token), request_id, value, value_len, att_error,
                                     payload, sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_respond_write(uint64_t request_id, uint64_t att_error,
                                          simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[256];
  int n = simble_encode_respond_write(token, sizeof(token), request_id, att_error, payload,
                                      sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_update_value(const char *service, size_t service_len,
                                         const char *characteristic, size_t char_len,
                                         const uint8_t *value, size_t value_len,
                                         const uint8_t *central_id, size_t central_len,
                                         simble_response *out) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t payload[2048];
  int n = simble_encode_update_value(token, sizeof(token), service, service_len, characteristic,
                                     char_len, value, value_len, central_id, central_len, payload,
                                     sizeof(payload));
  return do_request(payload, n, out);
}

simble_status simble_client_open(simble_conn *conn) {
  uint8_t token[32];
  if (read_token(token) != 0)
    return SIMBLE_ERR_TRUNCATED;
  int fd = connect_helper();
  if (fd < 0)
    return SIMBLE_ERR_TRUNCATED;
  conn->fd = fd;
  return SIMBLE_OK;
}

simble_status simble_client_read_event(simble_conn *conn, simble_event *out) {
  if (!conn || conn->fd < 0)
    return SIMBLE_ERR_TRUNCATED;
  uint8_t frame[8192];
  size_t frame_len = 0;
  simble_status st = read_frame(conn->fd, frame, sizeof(frame), &frame_len);
  if (st != SIMBLE_OK)
    return st;
  return simble_decode_event(frame, frame_len, out);
}

void simble_client_close(simble_conn *conn) {
  if (conn && conn->fd >= 0) {
    close(conn->fd);
    conn->fd = -1;
  }
}
