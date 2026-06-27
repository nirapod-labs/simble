/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file shadow_registry_test.m
 * @brief The shadow registry: mint, look up, and fail closed.
 *
 * @details
 * Minting returns one stable stand-in per host identifier, lookups resolve a minted
 * object back to its host identity, and an object the registry never minted resolves
 * to nothing, which is the fail-closed property the routing path depends on. No radio
 * and no helper.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#import "shadow.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <stdio.h>

static int fails = 0;
#define CHECK(cond, msg)                                                                           \
  do {                                                                                             \
    if (!(cond)) {                                                                                 \
      printf("FAIL: %s\n", msg);                                                                   \
      fails++;                                                                                     \
    }                                                                                              \
  } while (0)

int main(void) {
  @autoreleasepool {
    simble_shadow_reset();

    // A manager is managed once registered, and not before.
    CBCentralManager *manager = [CBCentralManager alloc];
    CHECK(!simble_shadow_is_managed_manager(manager), "an unregistered manager is not managed");
    simble_shadow_register_manager(manager, nil, nil);
    CHECK(simble_shadow_is_managed_manager(manager), "a registered manager is managed");

    // One stand-in per host identifier: the same id mints the same peripheral.
    const uint8_t idBytes[] = {0xde, 0xad, 0xbe, 0xef};
    CBPeripheral *p1 = simble_shadow_peripheral(manager, idBytes, sizeof(idBytes));
    CBPeripheral *p2 = simble_shadow_peripheral(manager, idBytes, sizeof(idBytes));
    CHECK(p1 != nil && p1 == p2, "one stand-in per identifier");
    CHECK(simble_shadow_is_managed_peripheral(p1), "a minted peripheral is managed");
    CHECK(simble_shadow_owner(p1) == manager, "the owner resolves to the minting manager");

    // The peripheral id round-trips.
    uint8_t out[64];
    size_t outLen = 0;
    CHECK(simble_shadow_peripheral_id(p1, out, sizeof(out), &outLen) && outLen == sizeof(idBytes) &&
              memcmp(out, idBytes, outLen) == 0,
          "the peripheral id round-trips");

    // A different id mints a different stand-in.
    const uint8_t otherBytes[] = {0x01, 0x02};
    CBPeripheral *other = simble_shadow_peripheral(manager, otherBytes, sizeof(otherBytes));
    CHECK(other != nil && other != p1, "a different identifier mints a different stand-in");

    // Services and characteristics mint under a minted peripheral and resolve back.
    CBUUID *serviceUUID = [CBUUID UUIDWithString:@"180D"];
    CBUUID *charUUID = [CBUUID UUIDWithString:@"2A37"];
    CBService *service = simble_shadow_service(p1, serviceUUID);
    CHECK(service != nil && service == simble_shadow_service(p1, serviceUUID),
          "one service stand-in per uuid");
    CBCharacteristic *characteristic = simble_shadow_characteristic(service, charUUID);
    CHECK(characteristic != nil &&
              characteristic == simble_shadow_characteristic(service, charUUID),
          "one characteristic stand-in per uuid");

    uint8_t rid[64];
    size_t ridLen = 0;
    CBUUID *resolvedService = nil;
    CBUUID *resolvedChar = nil;
    CHECK(simble_shadow_resolve_characteristic(characteristic, rid, sizeof(rid), &ridLen,
                                               &resolvedService, &resolvedChar),
          "a minted characteristic resolves");
    CHECK(ridLen == sizeof(idBytes) && memcmp(rid, idBytes, ridLen) == 0,
          "the resolved peripheral id matches the peripheral");
    CHECK([resolvedService isEqual:serviceUUID] && [resolvedChar isEqual:charUUID],
          "the resolved uuids match");

    // Fail closed: an object the registry never minted is not managed and does not resolve.
    CBCentralManager *strayManager = [CBCentralManager alloc];
    CHECK(!simble_shadow_is_managed_manager(strayManager), "a stray manager is not managed");
    CHECK(simble_shadow_peripheral(strayManager, idBytes, sizeof(idBytes)) == nil,
          "minting on an unregistered manager fails closed");
    CHECK(!simble_shadow_is_managed_peripheral((CBPeripheral *)manager),
          "a non-minted object is not a managed peripheral");
    CHECK(simble_shadow_service((CBPeripheral *)manager, serviceUUID) == nil,
          "a service on a non-minted peripheral fails closed");

    simble_shadow_reset();
    CHECK(!simble_shadow_is_managed_manager(manager), "reset drops every registration");
  }

  printf(fails ? "SHADOW REGISTRY: %d failure(s)\n" : "SHADOW REGISTRY: ok\n", fails);
  return fails ? 1 : 0;
}
