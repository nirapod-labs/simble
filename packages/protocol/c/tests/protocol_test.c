/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file protocol_test.c
 * @brief Unit checks for the C codec: encode, decode, reject paths, framing, parity vectors.
 *
 * @details
 * The encode vectors here are the exact bytes the Swift codec emits for the same
 * logical messages (see the Swift WireTests), so the two codecs are proven each
 * other's byte-for-byte oracle. The decode vectors are Swift-emitted responses and
 * events the interposer must parse.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#include <stdio.h>
#include <string.h>

#include "simble_protocol.h"

static int fails = 0;
#define CHECK(cond, msg)                                                                           \
  do {                                                                                             \
    if (!(cond)) {                                                                                 \
      printf("FAIL: %s\n", msg);                                                                   \
      fails++;                                                                                     \
    }                                                                                              \
  } while (0)

int main(void) {
  uint8_t buf[1024];
  uint8_t token[32];
  memset(token, 0xAB, sizeof(token));
  uint8_t pid[4] = {0x01, 0x02, 0x03, 0x04};
  uint8_t val[3] = {0xDE, 0xAD, 0xBE};

  CHECK(simble_protocol_version() == 1, "protocol version");
  CHECK(simble_protocol_version() == SIMBLE_PROTOCOL_VERSION, "version macro");

  // --- Parity vectors: the C encoder must emit exactly the bytes the Swift codec emits. ---

  // HELLO with identity: map(5) { 0:1, 7:token, 8:1, 14:"a", 28:"App" }.
  uint8_t hello_want[] = {0xA5, 0x00, 0x01, 0x07, 0x58, 0x20, 0xAB, 0xAB, 0xAB, 0xAB,
                          0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
                          0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
                          0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0x08, 0x01,
                          0x0E, 0x61, 0x61, 0x18, 0x1C, 0x63, 0x41, 0x70, 0x70};
  int n = simble_encode_hello(token, 32, 1, (const uint8_t *)"a", 1, (const uint8_t *)"App", 3, buf,
                              sizeof(buf));
  CHECK(n == (int)sizeof(hello_want) && memcmp(buf, hello_want, n) == 0, "hello parity");

  // A bare HELLO drops the two identity keys and matches the three-field shape.
  n = simble_encode_hello(token, 32, 1, NULL, 0, NULL, 0, buf, sizeof(buf));
  CHECK(n == 40 && buf[0] == 0xA3 && buf[38] == 0x08 && buf[39] == 0x01, "bare hello");

  // CENTRAL_STATE: map(2) { 0:2, 7:token }.
  n = simble_encode_command(2, token, 32, buf, sizeof(buf));
  CHECK(n == 38 && buf[0] == 0xA2 && buf[1] == 0x00 && buf[2] == 0x02 && buf[3] == 0x07 &&
            buf[4] == 0x58 && buf[5] == 0x20 && memcmp(buf + 6, token, 32) == 0,
        "central_state parity");

  // SCAN_START with a filter: map(3), ending 18 32 (key 50) 81 (array(1)) 64 "180D".
  const char *uuids[] = {"180D"};
  size_t uuid_lens[] = {4};
  n = simble_encode_scan_start(token, 32, uuids, uuid_lens, 1, buf, sizeof(buf));
  uint8_t scan_tail[] = {0x18, 0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44};
  CHECK(n == 46 && buf[0] == 0xA3 && memcmp(buf + 38, scan_tail, sizeof(scan_tail)) == 0,
        "scan_start filter parity");

  // SCAN_START with no filter is the bare command shape with op 3.
  n = simble_encode_scan_start(token, 32, NULL, NULL, 0, buf, sizeof(buf));
  CHECK(n == 38 && buf[0] == 0xA2 && buf[2] == 0x03, "scan_start no filter");

  // CONNECT: map(3), ending 18 1E (key 30) 44 (bstr(4)) 01 02 03 04.
  n = simble_encode_peripheral_command(5, token, 32, pid, 4, buf, sizeof(buf));
  uint8_t connect_tail[] = {0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04};
  CHECK(n == 45 && buf[0] == 0xA3 && buf[2] == 0x05 &&
            memcmp(buf + 38, connect_tail, sizeof(connect_tail)) == 0,
        "connect parity");

  // DISCOVER_SERVICES with a filter: map(4), ending peripheral (30) then key 50 array(1) "180D".
  const char *svc_uuids[] = {"180D"};
  size_t svc_uuid_lens[] = {4};
  n = simble_encode_discover_services(token, 32, pid, 4, svc_uuids, svc_uuid_lens, 1, buf,
                                      sizeof(buf));
  uint8_t disc_svc_tail[] = {0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18,
                             0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44};
  CHECK(n == 53 && buf[0] == 0xA4 && buf[2] == 0x07 &&
            memcmp(buf + 38, disc_svc_tail, sizeof(disc_svc_tail)) == 0,
        "discover_services filter parity");

  // DISCOVER_SERVICES with no filter is the peripheral-directed shape with op 7.
  n = simble_encode_discover_services(token, 32, pid, 4, NULL, NULL, 0, buf, sizeof(buf));
  CHECK(n == 45 && buf[0] == 0xA3 && buf[2] == 0x07 && buf[38] == 0x18 && buf[39] == 0x1E,
        "discover_services no filter");

  // DISCOVER_CHARACTERISTICS with a filter: map(5), peripheral (30), service (31), key 51 array(1).
  const char *chr_uuids[] = {"2A37"};
  size_t chr_uuid_lens[] = {4};
  n = simble_encode_discover_characteristics(token, 32, pid, 4, "180D", 4, chr_uuids, chr_uuid_lens,
                                             1, buf, sizeof(buf));
  uint8_t disc_chr_tail[] = {0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31,
                             0x38, 0x30, 0x44, 0x18, 0x33, 0x81, 0x64, 0x32, 0x41, 0x33, 0x37};
  CHECK(n == 60 && buf[0] == 0xA5 && buf[2] == 0x08 &&
            memcmp(buf + 38, disc_chr_tail, sizeof(disc_chr_tail)) == 0,
        "discover_characteristics filter parity");

  // DISCOVER_CHARACTERISTICS with no filter drops key 51: map(4), ending service (31).
  n = simble_encode_discover_characteristics(token, 32, pid, 4, "180D", 4, NULL, NULL, 0, buf,
                                             sizeof(buf));
  CHECK(n == 52 && buf[0] == 0xA4 && buf[2] == 0x08 && buf[n - 7] == 0x18 && buf[n - 6] == 0x1F,
        "discover_characteristics no filter");

  // READ_CHARACTERISTIC: map(5).
  n = simble_encode_read_characteristic(token, 32, pid, 4, "180D", 4, "2A37", 4, buf, sizeof(buf));
  uint8_t read_tail[] = {0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31,
                         0x38, 0x30, 0x44, 0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37};
  CHECK(n == 59 && buf[0] == 0xA5 && buf[2] == 0x09 &&
            memcmp(buf + 38, read_tail, sizeof(read_tail)) == 0,
        "read_characteristic parity");

  // WRITE_CHARACTERISTIC, withoutResponse: map(7), ending value (33) and writeType (39) = 1.
  n = simble_encode_write_characteristic(token, 32, pid, 4, "180D", 4, "2A37", 4, val, 3,
                                         SIMBLE_WRITE_WITHOUT_RESPONSE, buf, sizeof(buf));
  uint8_t write_tail[] = {0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE, 0x18, 0x27, 0x01};
  CHECK(n == 68 && buf[0] == 0xA7 && buf[2] == 0x0A &&
            memcmp(buf + n - (int)sizeof(write_tail), write_tail, sizeof(write_tail)) == 0,
        "write_characteristic parity");

  // SET_NOTIFY: map(6), ending notify (40) = 1.
  n = simble_encode_set_notify(token, 32, pid, 4, "180D", 4, "2A37", 4, 1, buf, sizeof(buf));
  CHECK(n == 62 && buf[0] == 0xA6 && buf[2] == 0x0B && buf[n - 3] == 0x18 && buf[n - 2] == 0x28 &&
            buf[n - 1] == 0x01,
        "set_notify parity");

  // RESPOND_READ: map(5) { 0:18, 7:token, 33:value, 42:requestId, 49:attError }.
  n = simble_encode_respond_read(token, 32, 7, val, 3, 0, buf, sizeof(buf));
  uint8_t respond_read_tail[] = {0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE,
                                 0x18, 0x2A, 0x07, 0x18, 0x31, 0x00};
  CHECK(n == 50 && buf[0] == 0xA5 && buf[2] == 0x12 &&
            memcmp(buf + 38, respond_read_tail, sizeof(respond_read_tail)) == 0,
        "respond_read parity");

  // RESPOND_WRITE: map(4) { 0:19, 7:token, 42:requestId, 49:attError }.
  n = simble_encode_respond_write(token, 32, 7, 0, buf, sizeof(buf));
  uint8_t respond_write_tail[] = {0x18, 0x2A, 0x07, 0x18, 0x31, 0x00};
  CHECK(n == 44 && buf[0] == 0xA4 && buf[2] == 0x13 &&
            memcmp(buf + 38, respond_write_tail, sizeof(respond_write_tail)) == 0,
        "respond_write parity");

  // ADD_SERVICE: map(7) { 0:14, 7:token, 31:"180D", 44:props, 45:perms, 46:1, 51:["2A37","2A38"] };
  // props and perms are packed byte strings, two-byte count then one eight-byte value each.
  const char *add_uuids[] = {"2A37", "2A38"};
  size_t add_uuid_lens[] = {4, 4};
  uint64_t props[] = {0x10, 0x08};
  uint64_t perms[] = {0x01, 0x02};
  n = simble_encode_add_service(token, 32, "180D", 4, 1, add_uuids, add_uuid_lens, props, perms, 2,
                                buf, sizeof(buf));
  uint8_t add_tail[] = {0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x2C, 0x52, 0x00, 0x02,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x08, 0x18, 0x2D, 0x52, 0x00, 0x02, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x02, 0x18, 0x2E, 0x01, 0x18, 0x33, 0x82, 0x64, 0x32, 0x41, 0x33, 0x37,
                        0x64, 0x32, 0x41, 0x33, 0x38};
  CHECK(n == 103 && buf[0] == 0xA7 && buf[2] == 0x0E &&
            memcmp(buf + 38, add_tail, sizeof(add_tail)) == 0,
        "add_service parity");

  // REMOVE_SERVICE: map(3) { 0:15, 7:token, 31:"180D" }.
  n = simble_encode_remove_service(token, 32, "180D", 4, buf, sizeof(buf));
  uint8_t remove_tail[] = {0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44};
  CHECK(n == 45 && buf[0] == 0xA3 && buf[2] == 0x0F &&
            memcmp(buf + 38, remove_tail, sizeof(remove_tail)) == 0,
        "remove_service parity");

  // START_ADVERTISING with name and UUIDs: map(4) { 0:16, 7:token, 35:"Dev", 36:["180D"] }.
  const char *adv_uuids[] = {"180D"};
  size_t adv_uuid_lens[] = {4};
  n = simble_encode_start_advertising(token, 32, "Dev", 3, adv_uuids, adv_uuid_lens, 1, buf,
                                      sizeof(buf));
  uint8_t advertise_tail[] = {0x18, 0x23, 0x63, 0x44, 0x65, 0x76,
                              0x18, 0x24, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44};
  CHECK(n == 52 && buf[0] == 0xA4 && buf[2] == 0x10 &&
            memcmp(buf + 38, advertise_tail, sizeof(advertise_tail)) == 0,
        "start_advertising parity");

  // START_ADVERTISING with neither name nor UUIDs is the token-only command shape with op 16.
  n = simble_encode_start_advertising(token, 32, NULL, 0, NULL, NULL, 0, buf, sizeof(buf));
  CHECK(n == 38 && buf[0] == 0xA2 && buf[2] == 0x10, "start_advertising bare");

  // UPDATE_VALUE to one central: map(6) { 0:20, 7:token, 31:"180D", 32:"2A37", 33:value, 47:cid }.
  uint8_t cid[2] = {0x09, 0x08};
  n = simble_encode_update_value(token, 32, "180D", 4, "2A37", 4, val, 3, cid, 2, buf, sizeof(buf));
  uint8_t update_tail[] = {0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x20, 0x64, 0x32,
                           0x41, 0x33, 0x37, 0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE, 0x18, 0x2F,
                           0x42, 0x09, 0x08};
  CHECK(n == 63 && buf[0] == 0xA6 && buf[2] == 0x14 &&
            memcmp(buf + 38, update_tail, sizeof(update_tail)) == 0,
        "update_value parity");

  // UPDATE_VALUE to every subscriber drops key 47: map(5).
  n = simble_encode_update_value(token, 32, "180D", 4, "2A37", 4, val, 3, NULL, 0, buf, sizeof(buf));
  CHECK(n == 58 && buf[0] == 0xA5 && buf[2] == 0x14, "update_value broadcast");

  // --- Decode responses the Swift codec emits. ---
  simble_response resp;

  uint8_t resp_hello[] = {0xA3, 0x00, 0x01, 0x01, 0x00, 0x08, 0x01};
  CHECK(simble_decode_response(resp_hello, sizeof(resp_hello), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_HELLO && resp.version == 1,
        "decode hello response");

  uint8_t resp_central_state[] = {0xA3, 0x00, 0x02, 0x01, 0x00, 0x18, 0x29, 0x05};
  CHECK(simble_decode_response(resp_central_state, sizeof(resp_central_state), &resp) ==
                SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CENTRAL_STATE && resp.manager_state == 5,
        "decode central_state response");

  uint8_t resp_scan_started[] = {0xA2, 0x00, 0x03, 0x01, 0x00};
  CHECK(simble_decode_response(resp_scan_started, sizeof(resp_scan_started), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED && resp.resp_op == 3,
        "decode scan_started response");

  uint8_t resp_connected[] = {0xA3, 0x00, 0x05, 0x01, 0x00, 0x18,
                              0x1E, 0x44, 0x01, 0x02, 0x03, 0x04};
  CHECK(simble_decode_response(resp_connected, sizeof(resp_connected), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_PERIPHERAL && resp.peripheral_len == 4 &&
            memcmp(resp.peripheral, pid, 4) == 0,
        "decode connected response");

  uint8_t resp_services[] = {0xA4, 0x00, 0x07, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01, 0x02,
                             0x03, 0x04, 0x18, 0x32, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44};
  CHECK(simble_decode_response(resp_services, sizeof(resp_services), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_SERVICES_DISCOVERED && resp.peripheral_len == 4 &&
            resp.uuid_count == 1 && strcmp(resp.uuids[0], "180D") == 0,
        "decode services_discovered response");

  uint8_t resp_chars[] = {0xA5, 0x00, 0x08, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01,
                          0x02, 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30,
                          0x44, 0x18, 0x33, 0x81, 0x64, 0x32, 0x41, 0x33, 0x37};
  CHECK(simble_decode_response(resp_chars, sizeof(resp_chars), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CHARS_DISCOVERED && strcmp(resp.service, "180D") == 0 &&
            resp.uuid_count == 1 && strcmp(resp.uuids[0], "2A37") == 0,
        "decode characteristics_discovered response");

  uint8_t resp_rssi[] = {0xA4, 0x00, 0x0C, 0x01, 0x00, 0x18, 0x1E, 0x44,
                         0x01, 0x02, 0x03, 0x04, 0x18, 0x22, 0x38, 0x29};
  CHECK(simble_decode_response(resp_rssi, sizeof(resp_rssi), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_RSSI && resp.rssi == -42 && resp.peripheral_len == 4,
        "decode rssi response");

  uint8_t resp_periph_state[] = {0xA4, 0x00, 0x0D, 0x01, 0x00, 0x18, 0x1E, 0x44,
                                 0x01, 0x02, 0x03, 0x04, 0x18, 0x29, 0x02};
  CHECK(simble_decode_response(resp_periph_state, sizeof(resp_periph_state), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_PERIPHERAL_STATE && resp.manager_state == 2,
        "decode peripheral_state response");

  uint8_t resp_char_value[] = {0xA6, 0x00, 0x09, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03,
                               0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x20, 0x64,
                               0x32, 0x41, 0x33, 0x37, 0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE};
  CHECK(simble_decode_response(resp_char_value, sizeof(resp_char_value), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CHAR_VALUE && strcmp(resp.service, "180D") == 0 &&
            strcmp(resp.characteristic, "2A37") == 0 && resp.value_len == 3 &&
            memcmp(resp.value, val, 3) == 0,
        "decode char_value response");

  uint8_t resp_notify_state[] = {0xA6, 0x00, 0x0B, 0x01, 0x00, 0x18, 0x1E, 0x44, 0x01, 0x02,
                                 0x03, 0x04, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18,
                                 0x20, 0x64, 0x32, 0x41, 0x33, 0x37, 0x18, 0x28, 0x01};
  CHECK(simble_decode_response(resp_notify_state, sizeof(resp_notify_state), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_NOTIFY_STATE && resp.notify == 1,
        "decode notify_state response");

  uint8_t resp_wrote[] = {0xA2, 0x00, 0x0A, 0x01, 0x00};
  CHECK(simble_decode_response(resp_wrote, sizeof(resp_wrote), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_CONFIRMED && resp.resp_op == 10,
        "decode wrote response");

  uint8_t resp_service_added[] = {0xA3, 0x00, 0x0E, 0x01, 0x00, 0x18, 0x1F, 0x64, 0x31, 0x38,
                                  0x30, 0x44};
  CHECK(simble_decode_response(resp_service_added, sizeof(resp_service_added), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_SERVICE && resp.resp_op == 14 &&
            strcmp(resp.service, "180D") == 0,
        "decode service_added response");

  uint8_t resp_service_removed[] = {0xA3, 0x00, 0x0F, 0x01, 0x00, 0x18, 0x1F, 0x64, 0x31, 0x38,
                                    0x30, 0x44};
  CHECK(simble_decode_response(resp_service_removed, sizeof(resp_service_removed), &resp) ==
                SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_SERVICE && resp.resp_op == 15 &&
            strcmp(resp.service, "180D") == 0,
        "decode service_removed response");

  uint8_t resp_failure[] = {0xA4, 0x00, 0x05, 0x01, 0x01, 0x06, 0x62, 0x6E, 0x6F, 0x0A, 0x26};
  CHECK(simble_decode_response(resp_failure, sizeof(resp_failure), &resp) == SIMBLE_OK &&
            resp.kind == SIMBLE_RESP_ERROR && resp.error_code == -7 &&
            strcmp(resp.error, "no") == 0 && resp.resp_op == 5,
        "decode failure response");

  // --- Decode events the Swift codec emits. ---
  simble_event evt;

  uint8_t evt_discovered[] = {0xA7, 0x00, 0x18, 0x80, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03,
                              0x04, 0x18, 0x22, 0x38, 0x36, 0x18, 0x23, 0x63, 0x44, 0x65,
                              0x76, 0x18, 0x24, 0x81, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18,
                              0x25, 0x27, 0x18, 0x26, 0x42, 0xCA, 0xFE};
  CHECK(simble_decode_event(evt_discovered, sizeof(evt_discovered), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_DISCOVERED && evt.rssi == -55 && evt.has_local_name &&
            strcmp(evt.local_name, "Dev") == 0 && evt.has_tx_power && evt.tx_power == -8 &&
            evt.has_mfg_data && evt.mfg_data_len == 2 && evt.mfg_data[0] == 0xCA &&
            evt.mfg_data[1] == 0xFE,
        "decode discovered event");

  uint8_t evt_char_value[] = {0xA5, 0x00, 0x18, 0x81, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04,
                              0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18, 0x20, 0x64, 0x32,
                              0x41, 0x33, 0x37, 0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE};
  CHECK(simble_decode_event(evt_char_value, sizeof(evt_char_value), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_CHAR_VALUE && strcmp(evt.service, "180D") == 0 &&
            evt.value_len == 3,
        "decode char_value event");

  uint8_t evt_disc_err[] = {0xA3, 0x00, 0x18, 0x82, 0x0A, 0x29, 0x18,
                            0x1E, 0x44, 0x01, 0x02, 0x03, 0x04};
  CHECK(simble_decode_event(evt_disc_err, sizeof(evt_disc_err), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_DISCONNECTED && evt.has_error_code && evt.error_code == -10,
        "decode disconnected event with error");

  uint8_t evt_disc_noerr[] = {0xA2, 0x00, 0x18, 0x82, 0x18, 0x1E, 0x44, 0x01, 0x02, 0x03, 0x04};
  CHECK(simble_decode_event(evt_disc_noerr, sizeof(evt_disc_noerr), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_DISCONNECTED && !evt.has_error_code,
        "decode disconnected event without error");

  uint8_t evt_central_changed[] = {0xA2, 0x00, 0x18, 0x83, 0x18, 0x29, 0x04};
  CHECK(simble_decode_event(evt_central_changed, sizeof(evt_central_changed), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_CENTRAL_STATE_CHANGED && evt.manager_state == 4,
        "decode central_state_changed event");

  uint8_t evt_read_req[] = {0xA6, 0x00, 0x18, 0x85, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30,
                            0x44, 0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37, 0x18, 0x2A,
                            0x03, 0x18, 0x2B, 0x00, 0x18, 0x2F, 0x42, 0x09, 0x08};
  CHECK(simble_decode_event(evt_read_req, sizeof(evt_read_req), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_READ_REQUEST && evt.request_id == 3 && evt.att_offset == 0 &&
            evt.central_len == 2 && evt.central[0] == 0x09 && evt.central[1] == 0x08,
        "decode read_request event");

  uint8_t evt_write_req[] = {0xA7, 0x00, 0x18, 0x86, 0x18, 0x1F, 0x64, 0x31, 0x38, 0x30, 0x44, 0x18,
                             0x20, 0x64, 0x32, 0x41, 0x33, 0x37, 0x18, 0x21, 0x43, 0xDE, 0xAD, 0xBE,
                             0x18, 0x2A, 0x03, 0x18, 0x2B, 0x01, 0x18, 0x2F, 0x42, 0x09, 0x08};
  CHECK(simble_decode_event(evt_write_req, sizeof(evt_write_req), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_WRITE_REQUEST && evt.request_id == 3 && evt.att_offset == 1 &&
            evt.value_len == 3 && evt.central_len == 2,
        "decode write_request event");

  uint8_t evt_subscribed[] = {0xA5, 0x00, 0x18, 0x87, 0x18, 0x1F, 0x64, 0x31, 0x38,
                              0x30, 0x44, 0x18, 0x20, 0x64, 0x32, 0x41, 0x33, 0x37,
                              0x18, 0x2F, 0x42, 0x09, 0x08, 0x18, 0x30, 0x18, 0xB9};
  CHECK(simble_decode_event(evt_subscribed, sizeof(evt_subscribed), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_SUBSCRIBED && evt.mtu == 185 && evt.central_len == 2,
        "decode subscribed event");

  uint8_t evt_unsubscribed[] = {0xA4, 0x00, 0x18, 0x88, 0x18, 0x1F, 0x64, 0x31,
                                0x38, 0x30, 0x44, 0x18, 0x20, 0x64, 0x32, 0x41,
                                0x33, 0x37, 0x18, 0x2F, 0x42, 0x09, 0x08};
  CHECK(simble_decode_event(evt_unsubscribed, sizeof(evt_unsubscribed), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_UNSUBSCRIBED && evt.central_len == 2,
        "decode unsubscribed event");

  uint8_t evt_ready[] = {0xA1, 0x00, 0x18, 0x89};
  CHECK(simble_decode_event(evt_ready, sizeof(evt_ready), &evt) == SIMBLE_OK &&
            evt.kind == SIMBLE_EVT_READY_TO_UPDATE,
        "decode ready_to_update event");

  // --- Framing. ---
  uint8_t framed[8];
  uint8_t pay[4] = {0xDE, 0xAD, 0xBE, 0xEF};
  CHECK(simble_frame(pay, 4, framed, sizeof(framed)) == 8, "frame len");
  uint8_t frame_want[] = {0, 0, 0, 4, 0xDE, 0xAD, 0xBE, 0xEF};
  CHECK(memcmp(framed, frame_want, 8) == 0, "frame bytes");
  uint8_t prefix[4] = {0, 0, 1, 0};
  CHECK(simble_payload_length(prefix) == 256, "payload length");
  uint8_t too_big[4] = {0x00, 0x20, 0x00, 0x01}; // 0x200001 > 1 MiB
  CHECK(simble_payload_length(too_big) == -1, "reject oversize frame");

  // --- Hardening: the decoders reject non-canonical CBOR. ---

  // A duplicate key.
  uint8_t dup_key[] = {0xA2, 0x00, 0x01, 0x00, 0x03};
  CHECK(simble_decode_response(dup_key, sizeof(dup_key), &resp) != SIMBLE_OK,
        "reject duplicate key");

  // A non-shortest-form integer (op 5 in the 1-byte form).
  uint8_t non_canon[] = {0xA2, 0x00, 0x18, 0x05, 0x01, 0x00};
  CHECK(simble_decode_response(non_canon, sizeof(non_canon), &resp) != SIMBLE_OK,
        "reject non-canonical");

  // Trailing bytes after a complete map.
  uint8_t trailing[] = {0xA2, 0x00, 0x03, 0x01, 0x00, 0xFF};
  CHECK(simble_decode_response(trailing, sizeof(trailing), &resp) != SIMBLE_OK,
        "reject trailing bytes");

  // A hostile 64-bit byte-string length: the additive bound would wrap, so it must
  // be caught as truncated rather than read out of bounds.
  uint8_t wrap_len[] = {0xA1, 0x18, 0x1E, 0x5B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
  CHECK(simble_decode_response(wrap_len, sizeof(wrap_len), &resp) == SIMBLE_ERR_TRUNCATED,
        "reject wrapping length");

  // An unknown event op is rejected.
  uint8_t bad_evt[] = {0xA1, 0x00, 0x18, 0xFE};
  CHECK(simble_decode_event(bad_evt, sizeof(bad_evt), &evt) == SIMBLE_ERR_OPCODE,
        "reject unknown event op");

  printf(fails ? "C CODEC: %d failure(s)\n" : "C CODEC: ok\n", fails);
  return fails ? 1 : 0;
}
