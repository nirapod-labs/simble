/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file central_hooks.m
 * @brief The central swizzle set: CBCentralManager and CBPeripheral interception.
 *
 * @details
 * The guest's central calls route to the host helper, and the host's events come back as
 * the guest's own CBCentralManagerDelegate and CBPeripheralDelegate callbacks, dispatched
 * on the queue the guest gave its manager. A call whose receiver the registry did not mint
 * passes through to the saved original implementation, so a non-managed CoreBluetooth user
 * is byte-for-byte unaffected. No key material, pairing secret, or bonding record crosses
 * the interposer: only GATT operations and byte payloads do.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#import "../registry/shadow.h"
#import "../transport/client.h"
#import "hooks_internal.h"
#import "simble_interpose.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

static simble_hook_stats g_stats = {0};
static pthread_mutex_t g_install_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_installed = 0;

simble_hook_stats *simble_internal_stats(void) { return &g_stats; }

// The guest's bundle id and display name, for the HELLO the helper shows. Guest-reported,
// names the app, gates nothing.
static size_t copyAppId(char *buf, size_t cap) {
  NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
  if (identifier && [identifier getCString:buf maxLength:cap encoding:NSUTF8StringEncoding]) {
    return strlen(buf);
  }
  return 0;
}

static size_t copyDisplayName(char *buf, size_t cap) {
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
  if ([name isKindOfClass:NSString.class] &&
      [name getCString:buf maxLength:cap encoding:NSUTF8StringEncoding] && buf[0] != '\0') {
    return strlen(buf);
  }
  return 0;
}

// Announce identity once per process, best-effort.
static void announceIdentityOnce(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    char appId[256];
    size_t idLen = copyAppId(appId, sizeof(appId));
    char name[256];
    size_t nameLen = copyDisplayName(name, sizeof(name));
    simble_response resp;
    simble_client_hello(SIMBLE_PROTOCOL_VERSION, idLen ? (const uint8_t *)appId : NULL, idLen,
                        nameLen ? (const uint8_t *)name : NULL, nameLen, &resp);
  });
}

// Dispatch a block on the manager's queue, the main queue when it gave none.
static void dispatchOnManagerQueue(SimbleManagerEntry *entry, dispatch_block_t block) {
  dispatch_queue_t queue = entry.queue ?: dispatch_get_main_queue();
  dispatch_async(queue, block);
}

// --- The event stream: one reader thread per managed manager, started on first scan/connect ---

// Translate one host event into the guest's delegate callbacks; runs on the reader thread,
// dispatches on the manager's queue.
static void deliverEvent(CBCentralManager *manager, const simble_event *event) {
  SimbleManagerEntry *entry = simble_shadow_manager_entry(manager);
  if (!entry)
    return;

  switch (event->kind) {
  case SIMBLE_EVT_DISCOVERED: {
    CBPeripheral *peripheral =
        simble_shadow_peripheral(manager, event->peripheral, event->peripheral_len);
    NSNumber *rssi = @(event->rssi);
    NSMutableDictionary *adv = [NSMutableDictionary dictionary];
    if (event->has_local_name) {
      adv[CBAdvertisementDataLocalNameKey] = [NSString stringWithUTF8String:event->local_name];
    }
    if (event->has_tx_power) {
      adv[CBAdvertisementDataTxPowerLevelKey] = @(event->tx_power);
    }
    if (event->has_mfg_data) {
      adv[CBAdvertisementDataManufacturerDataKey] = [NSData dataWithBytes:event->mfg_data
                                                                   length:event->mfg_data_len];
    }
    dispatchOnManagerQueue(entry, ^{
      id<CBCentralManagerDelegate> delegate = entry.delegate;
      if ([delegate respondsToSelector:
                        @selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:)]) {
        [delegate centralManager:manager
            didDiscoverPeripheral:peripheral
                advertisementData:adv
                             RSSI:rssi];
      }
    });
    break;
  }
  case SIMBLE_EVT_DISCONNECTED: {
    CBPeripheral *peripheral =
        simble_shadow_peripheral(manager, event->peripheral, event->peripheral_len);
    NSError *error = event->has_error_code ? [NSError errorWithDomain:CBErrorDomain
                                                                 code:event->error_code
                                                             userInfo:nil]
                                           : nil;
    dispatchOnManagerQueue(entry, ^{
      id<CBCentralManagerDelegate> delegate = entry.delegate;
      if ([delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:error:)]) {
        [delegate centralManager:manager didDisconnectPeripheral:peripheral error:error];
      }
    });
    break;
  }
  case SIMBLE_EVT_CENTRAL_STATE_CHANGED: {
    dispatchOnManagerQueue(entry, ^{
      id<CBCentralManagerDelegate> delegate = entry.delegate;
      if ([delegate respondsToSelector:@selector(centralManagerDidUpdateState:)]) {
        [delegate centralManagerDidUpdateState:manager];
      }
    });
    break;
  }
  case SIMBLE_EVT_CHAR_VALUE: {
    CBPeripheral *peripheral =
        simble_shadow_peripheral(manager, event->peripheral, event->peripheral_len);
    CBUUID *serviceUUID = [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->service]];
    CBUUID *charUUID =
        [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->characteristic]];
    CBService *service = simble_shadow_service(peripheral, serviceUUID);
    CBCharacteristic *characteristic = simble_shadow_characteristic(service, charUUID);
    NSData *value = [NSData dataWithBytes:event->value length:event->value_len];
    dispatchOnManagerQueue(entry, ^{
      id<CBPeripheralDelegate> delegate = peripheral.delegate;
      // Attach the value to the characteristic stand-in before the didUpdate callback reads it.
      objc_setAssociatedObject(characteristic, @selector(value), value,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      if ([delegate
              respondsToSelector:@selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
        [delegate peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:nil];
      }
    });
    break;
  }
  default:
    // A peripheral-role event routes to the peripheral delivery path.
    simble_deliver_peripheral_event(event);
    break;
  }
}

// The reader loop: drain the event connection, deliver each event, exit when the connection closes.
static void runEventReader(CBCentralManager *manager) {
  simble_conn conn;
  if (simble_client_open(&conn) != SIMBLE_OK)
    return;
  for (;;) {
    simble_event event;
    if (simble_client_read_event(&conn, &event) != SIMBLE_OK)
      break;
    deliverEvent(manager, &event);
  }
  simble_client_close(&conn);
}

// Start the event reader for a manager once, on the first scan or connect.
static void startEventReaderOnce(CBCentralManager *manager) {
  static const void *kReaderStartedKey = &kReaderStartedKey;
  @synchronized(manager) {
    if (objc_getAssociatedObject(manager, kReaderStartedKey))
      return;
    objc_setAssociatedObject(manager, kReaderStartedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  CBCentralManager *captured = manager;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    runEventReader(captured);
  });
}

// --- Swizzle plumbing ---

// Swizzle an instance method on a class: exchange original and routed IMPs; record the pair for
// uninstall.
typedef struct {
  Class cls;
  SEL original;
  SEL replacement;
} SwizzlePair;

static SwizzlePair g_pairs[24];
static size_t g_pair_count = 0;

int simble_swizzle(Class cls, SEL original, SEL replacement) {
  Method origMethod = class_getInstanceMethod(cls, original);
  Method replMethod = class_getInstanceMethod(cls, replacement);
  if (!origMethod || !replMethod)
    return -1;
  method_exchangeImplementations(origMethod, replMethod);
  if (g_pair_count < sizeof(g_pairs) / sizeof(g_pairs[0])) {
    g_pairs[g_pair_count++] = (SwizzlePair){cls, original, replacement};
  }
  return 0;
}

// --- CBCentralManager routed methods ---

@interface CBCentralManager (SimbleCentral)
@end

@implementation CBCentralManager (SimbleCentral)

// Register the manager with its delegate and queue, then return the manager the original built.
- (instancetype)simble_initWithDelegate:(id<CBCentralManagerDelegate>)delegate
                                  queue:(dispatch_queue_t)queue {
  CBCentralManager *manager = [self simble_initWithDelegate:delegate queue:queue];
  if (manager) {
    simble_shadow_register_manager(manager, delegate, queue);
    announceIdentityOnce();
    SimbleManagerEntry *entry = simble_shadow_manager_entry(manager);
    // Mirror CoreBluetooth's async first state update: centralManagerDidUpdateState: on the
    // manager's queue.
    dispatchOnManagerQueue(entry, ^{
      id<CBCentralManagerDelegate> d = entry.delegate;
      if ([d respondsToSelector:@selector(centralManagerDidUpdateState:)]) {
        [d centralManagerDidUpdateState:manager];
      }
    });
  }
  return manager;
}

- (CBManagerState)simble_state {
  if (!simble_shadow_is_managed_manager(self))
    return [self simble_state];
  simble_response resp;
  if (simble_client_central_state(&resp) == SIMBLE_OK && resp.kind == SIMBLE_RESP_CENTRAL_STATE) {
    return (CBManagerState)resp.manager_state;
  }
  return CBManagerStateUnknown;
}

- (void)simble_scanForPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs
                                      options:(NSDictionary<NSString *, id> *)options {
  if (!simble_shadow_is_managed_manager(self)) {
    [self simble_scanForPeripheralsWithServices:serviceUUIDs options:options];
    return;
  }
  startEventReaderOnce(self);
  size_t count = serviceUUIDs.count;
  const char **uuids = count ? calloc(count, sizeof(char *)) : NULL;
  size_t *lens = count ? calloc(count, sizeof(size_t)) : NULL;
  NSMutableArray<NSString *> *held = [NSMutableArray arrayWithCapacity:count];
  for (size_t i = 0; i < count; i++) {
    NSString *s = serviceUUIDs[i].UUIDString;
    [held addObject:s];
    uuids[i] = s.UTF8String;
    lens[i] = strlen(uuids[i]);
  }
  simble_response resp;
  simble_client_scan_start(uuids, lens, count, &resp);
  free(uuids);
  free(lens);
  g_stats.scan_start++;
}

- (void)simble_stopScan {
  if (!simble_shadow_is_managed_manager(self)) {
    [self simble_stopScan];
    return;
  }
  simble_response resp;
  simble_client_scan_stop(&resp);
}

- (void)simble_connectPeripheral:(CBPeripheral *)peripheral
                         options:(NSDictionary<NSString *, id> *)options {
  if (!simble_shadow_is_managed_manager(self) || !simble_shadow_is_managed_peripheral(peripheral)) {
    [self simble_connectPeripheral:peripheral options:options];
    return;
  }
  startEventReaderOnce(self);
  uint8_t pid[64];
  size_t idLen = 0;
  if (!simble_shadow_peripheral_id(peripheral, pid, sizeof(pid), &idLen))
    return;
  simble_response resp;
  simble_status st = simble_client_connect(pid, idLen, &resp);
  g_stats.connect++;
  SimbleManagerEntry *entry = simble_shadow_manager_entry(self);
  CBCentralManager *manager = self;
  dispatchOnManagerQueue(entry, ^{
    id<CBCentralManagerDelegate> delegate = entry.delegate;
    if (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_PERIPHERAL) {
      if ([delegate respondsToSelector:@selector(centralManager:didConnectPeripheral:)]) {
        [delegate centralManager:manager didConnectPeripheral:peripheral];
      }
    } else if ([delegate
                   respondsToSelector:@selector(
                                          centralManager:didFailToConnectPeripheral:error:)]) {
      NSError *error = [NSError errorWithDomain:CBErrorDomain code:resp.error_code userInfo:nil];
      [delegate centralManager:manager didFailToConnectPeripheral:peripheral error:error];
    }
  });
}

- (void)simble_cancelPeripheralConnection:(CBPeripheral *)peripheral {
  if (!simble_shadow_is_managed_manager(self) || !simble_shadow_is_managed_peripheral(peripheral)) {
    [self simble_cancelPeripheralConnection:peripheral];
    return;
  }
  uint8_t pid[64];
  size_t idLen = 0;
  if (!simble_shadow_peripheral_id(peripheral, pid, sizeof(pid), &idLen))
    return;
  simble_response resp;
  simble_status st = simble_client_disconnect(pid, idLen, &resp);
  SimbleManagerEntry *entry = simble_shadow_manager_entry(self);
  CBCentralManager *manager = self;
  dispatchOnManagerQueue(entry, ^{
    id<CBCentralManagerDelegate> delegate = entry.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_PERIPHERAL)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain
                                               code:resp.error_code
                                           userInfo:nil];
    if ([delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:error:)]) {
      [delegate centralManager:manager didDisconnectPeripheral:peripheral error:error];
    }
  });
}

@end

// --- CBPeripheral routed methods ---

@interface CBPeripheral (SimbleCentral)
@end

@implementation CBPeripheral (SimbleCentral)

// Resolve this peripheral's host id, or return NO when it is not a minted stand-in.
static BOOL peripheralRouteId(CBPeripheral *peripheral, uint8_t *out, size_t cap, size_t *outLen) {
  return simble_shadow_peripheral_id(peripheral, out, cap, outLen);
}

// Convert a CBUUID array filter to parallel UTF-8 string and length arrays held by an NSArray, so
// the encoder reads stable pointers. Returns the count; sets *uuidsOut and *lensOut to malloc'd
// arrays the caller frees, or NULL when the filter is empty.
static size_t buildUUIDFilter(NSArray<CBUUID *> *uuids, NSMutableArray<NSString *> *held,
                              const char ***uuidsOut, size_t **lensOut) {
  size_t count = uuids.count;
  if (count == 0) {
    *uuidsOut = NULL;
    *lensOut = NULL;
    return 0;
  }
  const char **strs = calloc(count, sizeof(char *));
  size_t *lens = calloc(count, sizeof(size_t));
  for (size_t i = 0; i < count; i++) {
    NSString *s = uuids[i].UUIDString;
    [held addObject:s];
    strs[i] = s.UTF8String;
    lens[i] = strlen(strs[i]);
  }
  *uuidsOut = strs;
  *lensOut = lens;
  return count;
}

- (void)simble_discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_discoverServices:serviceUUIDs];
    return;
  }
  // Route DISCOVER_SERVICES, mint a shadow service for each discovered UUID on this peripheral, and
  // deliver peripheral:didDiscoverServices:.
  uint8_t pid[64];
  size_t idLen = 0;
  if (!simble_shadow_peripheral_id(self, pid, sizeof(pid), &idLen))
    return;
  NSMutableArray<NSString *> *held = [NSMutableArray array];
  const char **uuids = NULL;
  size_t *lens = NULL;
  size_t count = buildUUIDFilter(serviceUUIDs, held, &uuids, &lens);
  simble_response resp;
  simble_status st = simble_client_discover_services(pid, idLen, uuids, lens, count, &resp);
  free(uuids);
  free(lens);
  g_stats.discover_services++;
  CBPeripheral *peripheral = self;
  if (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_SERVICES_DISCOVERED) {
    for (size_t i = 0; i < resp.uuid_count; i++) {
      CBUUID *uuid = [CBUUID UUIDWithString:[NSString stringWithUTF8String:resp.uuids[i]]];
      simble_shadow_service(peripheral, uuid);
    }
  }
  SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
  dispatchOnManagerQueue(entry, ^{
    id<CBPeripheralDelegate> delegate = peripheral.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_SERVICES_DISCOVERED)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain
                                               code:resp.error_code
                                           userInfo:nil];
    if ([delegate respondsToSelector:@selector(peripheral:didDiscoverServices:)]) {
      [delegate peripheral:peripheral didDiscoverServices:error];
    }
  });
}

- (void)simble_discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs
                            forService:(CBService *)service {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_discoverCharacteristics:characteristicUUIDs forService:service];
    return;
  }
  // Route DISCOVER_CHARACTERISTICS, mint a shadow characteristic for each discovered UUID on the
  // service, and deliver peripheral:didDiscoverCharacteristics:forService:error:.
  uint8_t pid[64];
  size_t idLen = 0;
  CBUUID *serviceUUID = nil;
  if (!simble_shadow_resolve_service(service, pid, sizeof(pid), &idLen, &serviceUUID))
    return;
  const char *svc = serviceUUID.UUIDString.UTF8String;
  NSMutableArray<NSString *> *held = [NSMutableArray array];
  const char **uuids = NULL;
  size_t *lens = NULL;
  size_t count = buildUUIDFilter(characteristicUUIDs, held, &uuids, &lens);
  simble_response resp;
  simble_status st = simble_client_discover_characteristics(pid, idLen, svc, strlen(svc), uuids,
                                                            lens, count, &resp);
  free(uuids);
  free(lens);
  g_stats.discover_characteristics++;
  CBPeripheral *peripheral = self;
  if (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CHARS_DISCOVERED) {
    for (size_t i = 0; i < resp.uuid_count; i++) {
      CBUUID *uuid = [CBUUID UUIDWithString:[NSString stringWithUTF8String:resp.uuids[i]]];
      simble_shadow_characteristic(service, uuid);
    }
  }
  SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
  dispatchOnManagerQueue(entry, ^{
    id<CBPeripheralDelegate> delegate = peripheral.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CHARS_DISCOVERED)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain
                                               code:resp.error_code
                                           userInfo:nil];
    if ([delegate
            respondsToSelector:@selector(peripheral:didDiscoverCharacteristicsForService:error:)]) {
      [delegate peripheral:peripheral didDiscoverCharacteristicsForService:service error:error];
    }
  });
}

- (void)simble_readValueForCharacteristic:(CBCharacteristic *)characteristic {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_readValueForCharacteristic:characteristic];
    return;
  }
  uint8_t pid[64];
  size_t idLen = 0;
  CBUUID *serviceUUID = nil;
  CBUUID *charUUID = nil;
  if (!simble_shadow_resolve_characteristic(characteristic, pid, sizeof(pid), &idLen, &serviceUUID,
                                            &charUUID)) {
    return;
  }
  const char *service = serviceUUID.UUIDString.UTF8String;
  const char *chr = charUUID.UUIDString.UTF8String;
  simble_response resp;
  simble_status st = simble_client_read_characteristic(pid, idLen, service, strlen(service), chr,
                                                       strlen(chr), &resp);
  g_stats.read++;
  CBPeripheral *peripheral = self;
  SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
  dispatchOnManagerQueue(entry, ^{
    id<CBPeripheralDelegate> delegate = peripheral.delegate;
    NSError *error = nil;
    if (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CHAR_VALUE) {
      NSData *value = [NSData dataWithBytes:resp.value length:resp.value_len];
      objc_setAssociatedObject(characteristic, @selector(value), value,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
      error = [NSError errorWithDomain:CBErrorDomain code:resp.error_code userInfo:nil];
    }
    if ([delegate
            respondsToSelector:@selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
      [delegate peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:error];
    }
  });
}

- (void)simble_writeValue:(NSData *)data
        forCharacteristic:(CBCharacteristic *)characteristic
                     type:(CBCharacteristicWriteType)type {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_writeValue:data forCharacteristic:characteristic type:type];
    return;
  }
  uint8_t pid[64];
  size_t idLen = 0;
  CBUUID *serviceUUID = nil;
  CBUUID *charUUID = nil;
  if (!simble_shadow_resolve_characteristic(characteristic, pid, sizeof(pid), &idLen, &serviceUUID,
                                            &charUUID)) {
    return;
  }
  const char *service = serviceUUID.UUIDString.UTF8String;
  const char *chr = charUUID.UUIDString.UTF8String;
  simble_write_type writeType = (type == CBCharacteristicWriteWithoutResponse)
                                    ? SIMBLE_WRITE_WITHOUT_RESPONSE
                                    : SIMBLE_WRITE_WITH_RESPONSE;
  simble_response resp;
  simble_status st =
      simble_client_write_characteristic(pid, idLen, service, strlen(service), chr, strlen(chr),
                                         data.bytes, data.length, writeType, &resp);
  g_stats.write++;
  // A withResponse write reports completion through didWriteValueForCharacteristic:; a
  // withoutResponse write reports nothing.
  if (type == CBCharacteristicWriteWithResponse) {
    CBPeripheral *peripheral = self;
    SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
    dispatchOnManagerQueue(entry, ^{
      id<CBPeripheralDelegate> delegate = peripheral.delegate;
      NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED)
                           ? nil
                           : [NSError errorWithDomain:CBErrorDomain
                                                 code:resp.error_code
                                             userInfo:nil];
      if ([delegate
              respondsToSelector:@selector(peripheral:didWriteValueForCharacteristic:error:)]) {
        [delegate peripheral:peripheral didWriteValueForCharacteristic:characteristic error:error];
      }
    });
  }
}

- (void)simble_setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_setNotifyValue:enabled forCharacteristic:characteristic];
    return;
  }
  uint8_t pid[64];
  size_t idLen = 0;
  CBUUID *serviceUUID = nil;
  CBUUID *charUUID = nil;
  if (!simble_shadow_resolve_characteristic(characteristic, pid, sizeof(pid), &idLen, &serviceUUID,
                                            &charUUID)) {
    return;
  }
  const char *service = serviceUUID.UUIDString.UTF8String;
  const char *chr = charUUID.UUIDString.UTF8String;
  simble_response resp;
  simble_status st = simble_client_set_notify(pid, idLen, service, strlen(service), chr,
                                              strlen(chr), enabled ? 1 : 0, &resp);
  g_stats.set_notify++;
  CBPeripheral *peripheral = self;
  SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
  dispatchOnManagerQueue(entry, ^{
    id<CBPeripheralDelegate> delegate = peripheral.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_NOTIFY_STATE)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain
                                               code:resp.error_code
                                           userInfo:nil];
    if ([delegate respondsToSelector:
                      @selector(peripheral:didUpdateNotificationStateForCharacteristic:error:)]) {
      [delegate peripheral:peripheral
          didUpdateNotificationStateForCharacteristic:characteristic
                                                error:error];
    }
  });
}

- (void)simble_readRSSI {
  if (!simble_shadow_is_managed_peripheral(self)) {
    [self simble_readRSSI];
    return;
  }
  uint8_t pid[64];
  size_t idLen = 0;
  if (!peripheralRouteId(self, pid, sizeof(pid), &idLen))
    return;
  simble_response resp;
  simble_status st = simble_client_read_rssi(pid, idLen, &resp);
  CBPeripheral *peripheral = self;
  SimbleManagerEntry *entry = simble_shadow_manager_entry(simble_shadow_owner(self));
  dispatchOnManagerQueue(entry, ^{
    id<CBPeripheralDelegate> delegate = peripheral.delegate;
    if (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_RSSI) {
      if ([delegate respondsToSelector:@selector(peripheral:didReadRSSI:error:)]) {
        [delegate peripheral:peripheral didReadRSSI:@(resp.rssi) error:nil];
      }
    } else if ([delegate respondsToSelector:@selector(peripheral:didReadRSSI:error:)]) {
      NSError *error = [NSError errorWithDomain:CBErrorDomain code:resp.error_code userInfo:nil];
      [delegate peripheral:peripheral didReadRSSI:@0 error:error];
    }
  });
}

@end

// `state` is declared on the shared CBManager superclass, so swizzling it on CBCentralManager would
// also intercept CBPeripheralManager and route a peripheral manager into the central state path.
// This IMP calls the superclass state, installed on CBCentralManager so the swizzle stays there.
static CBManagerState simble_central_state_super(id self, SEL _cmd) {
  (void)_cmd;
  struct objc_super sup = {self, [CBCentralManager superclass]};
  CBManagerState (*send)(struct objc_super *, SEL) =
      (CBManagerState(*)(struct objc_super *, SEL))objc_msgSendSuper;
  return send(&sup, @selector(state));
}

int simble_install_hooks(void) {
  pthread_mutex_lock(&g_install_lock);
  if (g_installed) {
    pthread_mutex_unlock(&g_install_lock);
    return 0;
  }
  int failures = 0;
  Class managerClass = [CBCentralManager class];
  failures += simble_swizzle(managerClass, @selector(initWithDelegate:queue:),
                             @selector(simble_initWithDelegate:queue:));
  class_addMethod(managerClass, @selector(state), (IMP)simble_central_state_super, "q@:");
  failures += simble_swizzle(managerClass, @selector(state), @selector(simble_state));
  failures += simble_swizzle(managerClass, @selector(scanForPeripheralsWithServices:options:),
                             @selector(simble_scanForPeripheralsWithServices:options:));
  failures += simble_swizzle(managerClass, @selector(stopScan), @selector(simble_stopScan));
  failures += simble_swizzle(managerClass, @selector(connectPeripheral:options:),
                             @selector(simble_connectPeripheral:options:));
  failures += simble_swizzle(managerClass, @selector(cancelPeripheralConnection:),
                             @selector(simble_cancelPeripheralConnection:));

  Class peripheralClass = [CBPeripheral class];
  failures += simble_swizzle(peripheralClass, @selector(discoverServices:),
                             @selector(simble_discoverServices:));
  failures += simble_swizzle(peripheralClass, @selector(discoverCharacteristics:forService:),
                             @selector(simble_discoverCharacteristics:forService:));
  failures += simble_swizzle(peripheralClass, @selector(readValueForCharacteristic:),
                             @selector(simble_readValueForCharacteristic:));
  failures += simble_swizzle(peripheralClass, @selector(writeValue:forCharacteristic:type:),
                             @selector(simble_writeValue:forCharacteristic:type:));
  failures += simble_swizzle(peripheralClass, @selector(setNotifyValue:forCharacteristic:),
                             @selector(simble_setNotifyValue:forCharacteristic:));
  failures += simble_swizzle(peripheralClass, @selector(readRSSI), @selector(simble_readRSSI));

  failures += simble_install_peripheral_hooks();

  g_installed = (failures == 0);
  pthread_mutex_unlock(&g_install_lock);
  return failures;
}

void simble_uninstall_hooks(void) {
  pthread_mutex_lock(&g_install_lock);
  if (!g_installed) {
    pthread_mutex_unlock(&g_install_lock);
    return;
  }
  // Exchange each pair back to restore the originals.
  for (size_t i = g_pair_count; i-- > 0;) {
    Method orig = class_getInstanceMethod(g_pairs[i].cls, g_pairs[i].original);
    Method repl = class_getInstanceMethod(g_pairs[i].cls, g_pairs[i].replacement);
    if (orig && repl)
      method_exchangeImplementations(orig, repl);
  }
  g_pair_count = 0;
  g_installed = 0;
  pthread_mutex_unlock(&g_install_lock);
}

simble_hook_stats simble_get_hook_stats(void) { return g_stats; }

int simble_interpose_version(void) { return 1; }
