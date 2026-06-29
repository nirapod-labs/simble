/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file shadow.m
 * @brief Shadow registry implementation: stand-in CoreBluetooth objects behind one lock.
 *
 * @details
 * CBPeripheral, CBService, and CBCharacteristic cannot be constructed through their
 * public API, so stand-ins are runtime subclasses of the CB classes with a no-op dealloc
 * (see shadowDealloc). The interposer never reads CoreBluetooth's private ivars: a
 * stand-in's identity is the associated state and the registry's own tables, so an object
 * the registry did not mint resolves to nothing and is treated as not managed.
 *
 * @see shadow.h for the API documentation.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#import "shadow.h"

#import <objc/runtime.h>

@implementation SimbleManagerEntry
@end

@implementation SimblePeripheralManagerEntry
@end

// Identity attached to a minted peripheral, service, or characteristic. A minted object
// carries one of these as associated state; absence of it is what "not managed" means.
@interface SimbleShadowMeta : NSObject
@property(nonatomic, strong) NSData *peripheralId; // peripheral id (peripheral, service, char)
@property(nonatomic, strong, nullable) CBUUID *serviceUUID;        // service and characteristic
@property(nonatomic, strong, nullable) CBUUID *characteristicUUID; // characteristic only
@property(nonatomic, weak, nullable) CBCentralManager *owner;      // owning manager (peripheral)
@property(nonatomic, weak, nullable) CBPeripheral *peripheral;     // owning peripheral (service)
@property(nonatomic, strong, nullable)
    NSMutableArray *children;                              // attached services or characteristics
@property(nonatomic, strong, nullable) NSUUID *identifier; // central identifier (central)
@property(nonatomic, assign) NSUInteger mtu;               // maximumUpdateValueLength (central)
@property(nonatomic, assign) uint64_t requestId;          // request id (ATT request)
@property(nonatomic, assign) BOOL isWrite;                // write request flag (ATT request)
@property(nonatomic, assign) NSUInteger offset;          // ATT offset (ATT request)
@property(nonatomic, strong, nullable) NSData *value;    // read/write value (ATT request)
@property(nonatomic, strong, nullable) CBCharacteristic *characteristic; // request char (ATT request)
@property(nonatomic, strong, nullable) CBCentral *central;               // origin central (ATT request)
@end

@implementation SimbleShadowMeta
@end

static const void *kShadowMetaKey = &kShadowMetaKey;

// One lock guards all of the tables below.
static NSLock *g_lock;

// Registered managers, keyed by the manager pointer (NSValue of a non-retained pointer); the
// value is the SimbleManagerEntry. Strong on the entry, weak on the manager via the entry's
// delegate property, mirroring CoreBluetooth's weak delegate.
static NSMutableDictionary<NSValue *, SimbleManagerEntry *> *g_managers;

// Minted peripherals, keyed by "<manager pointer>:<peripheral id hex>", so one stand-in is
// returned per identifier per manager. Retained for the process lifetime; the pointer is never
// freed or reused.
static NSMutableDictionary<NSString *, CBPeripheral *> *g_peripherals;
// Minted services, keyed by "<peripheral pointer>:<service uuid>".
static NSMutableDictionary<NSString *, CBService *> *g_services;
// Minted characteristics, keyed by "<service pointer>:<characteristic uuid>".
static NSMutableDictionary<NSString *, CBCharacteristic *> *g_characteristics;
// The set of minted object pointers, the membership authority for the fail-closed check.
static NSMutableSet<NSValue *> *g_minted;

// The registered peripheral managers, keyed by the manager pointer; the value is the
// SimblePeripheralManagerEntry. One GATT database per process; events resolve to the latest entry.
static NSMutableDictionary<NSValue *, SimblePeripheralManagerEntry *> *g_peripheral_managers;
// The guest's tracked CBMutableCharacteristics, keyed by "<service uuid>:<characteristic uuid>".
static NSMutableDictionary<NSString *, CBMutableCharacteristic *> *g_tracked_characteristics;
// The characteristic UUID strings of each tracked service, keyed by service UUID, for untracking.
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *g_tracked_services;
// Minted centrals, keyed by the central id hex, so one stand-in is returned per identifier.
static NSMutableDictionary<NSString *, CBCentral *> *g_centrals;

// A no-op dealloc, installed on each stand-in subclass. A bare instance of a CoreBluetooth class
// was never run through CoreBluetooth's own initializer, so the framework's dealloc (which tears
// down KVO registrations the initializer made) must not run on it; this leaves the object's own
// memory to the runtime to free after dealloc returns.
static void shadowDealloc(id self, SEL _cmd) {
  (void)self;
  (void)_cmd;
}

// Return the attached child list (services on a peripheral, characteristics on a service) the
// registry minted, snapshotted under the lock. CoreBluetooth's own getter reads private ivars a
// stand-in never had, so the stand-in answers from the registry instead.
static id shadowChildren(id self, SEL _cmd);

// Stand-in property getters, each answering from the attached meta in place of a private ivar.
static id shadowIdentifier(id self, SEL _cmd);
static NSUInteger shadowMtu(id self, SEL _cmd);
static id shadowCentral(id self, SEL _cmd);
static id shadowCharacteristic(id self, SEL _cmd);
static NSUInteger shadowOffset(id self, SEL _cmd);
static id shadowValue(id self, SEL _cmd);
static void shadowSetValue(id self, SEL _cmd, id value);

// Build a stand-in subclass of a CoreBluetooth class with the no-op dealloc, once per class.
static Class makeShadowSubclass(Class base, const char *name) {
  Class cls = objc_allocateClassPair(base, name, 0);
  class_addMethod(cls, sel_registerName("dealloc"), (IMP)shadowDealloc, "v@:");
  objc_registerClassPair(cls);
  return cls;
}

static Class g_peripheralShadowClass;
static Class g_serviceShadowClass;
static Class g_characteristicShadowClass;
static Class g_centralShadowClass;
static Class g_attRequestShadowClass;

__attribute__((constructor)) static void simble_shadow_init(void) {
  g_lock = [NSLock new];
  g_managers = [NSMutableDictionary new];
  g_peripherals = [NSMutableDictionary new];
  g_services = [NSMutableDictionary new];
  g_characteristics = [NSMutableDictionary new];
  g_minted = [NSMutableSet new];
  g_peripheral_managers = [NSMutableDictionary new];
  g_tracked_characteristics = [NSMutableDictionary new];
  g_tracked_services = [NSMutableDictionary new];
  g_centrals = [NSMutableDictionary new];
  g_peripheralShadowClass = makeShadowSubclass([CBPeripheral class], "SimbleShadowPeripheral");
  g_serviceShadowClass = makeShadowSubclass([CBService class], "SimbleShadowService");
  g_characteristicShadowClass =
      makeShadowSubclass([CBCharacteristic class], "SimbleShadowCharacteristic");
  g_centralShadowClass = makeShadowSubclass([CBCentral class], "SimbleShadowCentral");
  g_attRequestShadowClass = makeShadowSubclass([CBATTRequest class], "SimbleShadowATTRequest");
  // The stand-in peripheral's services and the stand-in service's characteristics answer from the
  // registry's attached child list.
  class_addMethod(g_peripheralShadowClass, sel_registerName("services"), (IMP)shadowChildren,
                  "@@:");
  class_addMethod(g_serviceShadowClass, sel_registerName("characteristics"), (IMP)shadowChildren,
                  "@@:");
  // The stand-in central answers its identifier and maximumUpdateValueLength from the meta.
  class_addMethod(g_centralShadowClass, sel_registerName("identifier"), (IMP)shadowIdentifier,
                  "@@:");
  class_addMethod(g_centralShadowClass, sel_registerName("maximumUpdateValueLength"),
                  (IMP)shadowMtu, "L@:");
  // The stand-in ATT request answers central, characteristic, offset, and value from the meta, and
  // its value setter records the read answer the guest sets before responding.
  class_addMethod(g_attRequestShadowClass, sel_registerName("central"), (IMP)shadowCentral, "@@:");
  class_addMethod(g_attRequestShadowClass, sel_registerName("characteristic"),
                  (IMP)shadowCharacteristic, "@@:");
  class_addMethod(g_attRequestShadowClass, sel_registerName("offset"), (IMP)shadowOffset, "L@:");
  class_addMethod(g_attRequestShadowClass, sel_registerName("value"), (IMP)shadowValue, "@@:");
  class_addMethod(g_attRequestShadowClass, sel_registerName("setValue:"), (IMP)shadowSetValue,
                  "v@:@");
}

static NSValue *ptr(id object) { return [NSValue valueWithPointer:(__bridge const void *)object]; }

static NSString *hexOf(const uint8_t *bytes, size_t len) {
  NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
  for (size_t i = 0; i < len; i++)
    [s appendFormat:@"%02x", bytes[i]];
  return s;
}

// Create a stand-in instance of a shadow subclass. The instance carries no CoreBluetooth state;
// the interposer reads only the associated identity it attaches.
static id mintInstance(Class cls) { return class_createInstance(cls, 0); }

static SimbleShadowMeta *metaOf(id object) {
  return object ? objc_getAssociatedObject(object, kShadowMetaKey) : nil;
}

static id shadowChildren(id self, SEL _cmd) {
  (void)_cmd;
  SimbleShadowMeta *meta = metaOf(self);
  [g_lock lock];
  NSArray *snapshot = meta.children ? [meta.children copy] : @[];
  [g_lock unlock];
  return snapshot;
}

static id shadowIdentifier(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).identifier;
}

static NSUInteger shadowMtu(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).mtu;
}

static id shadowCentral(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).central;
}

static id shadowCharacteristic(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).characteristic;
}

static NSUInteger shadowOffset(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).offset;
}

static id shadowValue(id self, SEL _cmd) {
  (void)_cmd;
  return metaOf(self).value;
}

static void shadowSetValue(id self, SEL _cmd, id value) {
  (void)_cmd;
  metaOf(self).value = value;
}

void simble_shadow_register_manager(CBCentralManager *manager,
                                    id<CBCentralManagerDelegate> delegate, dispatch_queue_t queue) {
  if (!manager)
    return;
  SimbleManagerEntry *entry = [SimbleManagerEntry new];
  entry.delegate = delegate;
  entry.queue = queue;
  [g_lock lock];
  g_managers[ptr(manager)] = entry;
  [g_lock unlock];
}

BOOL simble_shadow_is_managed_manager(CBCentralManager *manager) {
  if (!manager)
    return NO;
  [g_lock lock];
  BOOL found = g_managers[ptr(manager)] != nil;
  [g_lock unlock];
  return found;
}

SimbleManagerEntry *simble_shadow_manager_entry(CBCentralManager *manager) {
  if (!manager)
    return nil;
  [g_lock lock];
  SimbleManagerEntry *entry = g_managers[ptr(manager)];
  [g_lock unlock];
  return entry;
}

CBPeripheral *simble_shadow_peripheral(CBCentralManager *manager, const uint8_t *peripheralId,
                                       size_t peripheralLen) {
  if (!manager || !peripheralId || peripheralLen == 0)
    return nil;
  // Fail closed: only a managed manager mints peripherals.
  if (!simble_shadow_is_managed_manager(manager))
    return nil;
  NSString *key =
      [NSString stringWithFormat:@"%p:%@", (void *)manager, hexOf(peripheralId, peripheralLen)];
  [g_lock lock];
  CBPeripheral *existing = g_peripherals[key];
  if (existing) {
    [g_lock unlock];
    return existing;
  }
  CBPeripheral *minted = mintInstance(g_peripheralShadowClass);
  SimbleShadowMeta *meta = [SimbleShadowMeta new];
  meta.peripheralId = [NSData dataWithBytes:peripheralId length:peripheralLen];
  meta.owner = manager;
  objc_setAssociatedObject(minted, kShadowMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  g_peripherals[key] = minted;
  [g_minted addObject:ptr(minted)];
  [g_lock unlock];
  return minted;
}

BOOL simble_shadow_is_managed_peripheral(CBPeripheral *peripheral) {
  if (!peripheral)
    return NO;
  [g_lock lock];
  BOOL found = [g_minted containsObject:ptr(peripheral)];
  [g_lock unlock];
  return found;
}

BOOL simble_shadow_peripheral_id(CBPeripheral *peripheral, uint8_t *out, size_t cap,
                                 size_t *outLen) {
  if (!simble_shadow_is_managed_peripheral(peripheral))
    return NO;
  SimbleShadowMeta *meta = metaOf(peripheral);
  NSData *pidData = meta.peripheralId;
  if (!pidData || (size_t)pidData.length > cap)
    return NO;
  memcpy(out, pidData.bytes, pidData.length);
  *outLen = pidData.length;
  return YES;
}

CBCentralManager *simble_shadow_owner(CBPeripheral *peripheral) {
  if (!simble_shadow_is_managed_peripheral(peripheral))
    return nil;
  return metaOf(peripheral).owner;
}

CBService *simble_shadow_service(CBPeripheral *peripheral, CBUUID *serviceUUID) {
  if (!simble_shadow_is_managed_peripheral(peripheral) || !serviceUUID)
    return nil;
  NSString *key = [NSString stringWithFormat:@"%p:%@", (void *)peripheral, serviceUUID.UUIDString];
  [g_lock lock];
  CBService *existing = g_services[key];
  if (existing) {
    [g_lock unlock];
    return existing;
  }
  SimbleShadowMeta *pmeta = metaOf(peripheral);
  CBService *minted = mintInstance(g_serviceShadowClass);
  SimbleShadowMeta *meta = [SimbleShadowMeta new];
  meta.peripheralId = pmeta.peripheralId;
  meta.serviceUUID = serviceUUID;
  meta.peripheral = peripheral;
  objc_setAssociatedObject(minted, kShadowMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  g_services[key] = minted;
  [g_minted addObject:ptr(minted)];
  // Attach the minted service to the peripheral so its services getter returns it.
  if (!pmeta.children)
    pmeta.children = [NSMutableArray new];
  [pmeta.children addObject:minted];
  [g_lock unlock];
  return minted;
}

CBCharacteristic *simble_shadow_characteristic(CBService *service, CBUUID *characteristicUUID) {
  if (!service || !characteristicUUID)
    return nil;
  [g_lock lock];
  BOOL serviceMinted = [g_minted containsObject:ptr(service)];
  [g_lock unlock];
  if (!serviceMinted)
    return nil;
  NSString *key =
      [NSString stringWithFormat:@"%p:%@", (void *)service, characteristicUUID.UUIDString];
  [g_lock lock];
  CBCharacteristic *existing = g_characteristics[key];
  if (existing) {
    [g_lock unlock];
    return existing;
  }
  SimbleShadowMeta *smeta = metaOf(service);
  CBCharacteristic *minted = mintInstance(g_characteristicShadowClass);
  SimbleShadowMeta *meta = [SimbleShadowMeta new];
  meta.peripheralId = smeta.peripheralId;
  meta.serviceUUID = smeta.serviceUUID;
  meta.characteristicUUID = characteristicUUID;
  objc_setAssociatedObject(minted, kShadowMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  g_characteristics[key] = minted;
  [g_minted addObject:ptr(minted)];
  // Attach the minted characteristic to the service so its characteristics getter returns it.
  if (!smeta.children)
    smeta.children = [NSMutableArray new];
  [smeta.children addObject:minted];
  [g_lock unlock];
  return minted;
}

BOOL simble_shadow_resolve_service(CBService *service, uint8_t *peripheralOut, size_t peripheralCap,
                                   size_t *peripheralLen, CBUUID *_Nullable *_Nonnull serviceUUID) {
  if (!service)
    return NO;
  [g_lock lock];
  BOOL minted = [g_minted containsObject:ptr(service)];
  [g_lock unlock];
  if (!minted)
    return NO;
  SimbleShadowMeta *meta = metaOf(service);
  NSData *pidData = meta.peripheralId;
  if (!pidData || (size_t)pidData.length > peripheralCap)
    return NO;
  memcpy(peripheralOut, pidData.bytes, pidData.length);
  *peripheralLen = pidData.length;
  *serviceUUID = meta.serviceUUID;
  return YES;
}

BOOL simble_shadow_resolve_characteristic(CBCharacteristic *characteristic, uint8_t *peripheralOut,
                                          size_t peripheralCap, size_t *peripheralLen,
                                          CBUUID *_Nullable *_Nonnull serviceUUID,
                                          CBUUID *_Nullable *_Nonnull characteristicUUID) {
  if (!characteristic)
    return NO;
  [g_lock lock];
  BOOL minted = [g_minted containsObject:ptr(characteristic)];
  [g_lock unlock];
  if (!minted)
    return NO;
  SimbleShadowMeta *meta = metaOf(characteristic);
  NSData *pidData = meta.peripheralId;
  if (!pidData || (size_t)pidData.length > peripheralCap)
    return NO;
  memcpy(peripheralOut, pidData.bytes, pidData.length);
  *peripheralLen = pidData.length;
  *serviceUUID = meta.serviceUUID;
  *characteristicUUID = meta.characteristicUUID;
  return YES;
}

void simble_shadow_register_peripheral_manager(CBPeripheralManager *manager,
                                               id<CBPeripheralManagerDelegate> delegate,
                                               dispatch_queue_t queue) {
  if (!manager)
    return;
  SimblePeripheralManagerEntry *entry = [SimblePeripheralManagerEntry new];
  entry.manager = manager;
  entry.delegate = delegate;
  entry.queue = queue;
  [g_lock lock];
  g_peripheral_managers[ptr(manager)] = entry;
  [g_lock unlock];
}

BOOL simble_shadow_is_managed_peripheral_manager(CBPeripheralManager *manager) {
  if (!manager)
    return NO;
  [g_lock lock];
  BOOL found = g_peripheral_managers[ptr(manager)] != nil;
  [g_lock unlock];
  return found;
}

SimblePeripheralManagerEntry *simble_shadow_peripheral_manager_entry(void) {
  [g_lock lock];
  SimblePeripheralManagerEntry *entry = g_peripheral_managers.allValues.lastObject;
  [g_lock unlock];
  return entry;
}

void simble_shadow_track_service(CBMutableService *service) {
  if (!service)
    return;
  NSString *svc = service.UUID.UUIDString;
  [g_lock lock];
  NSMutableArray<NSString *> *charUUIDs = [NSMutableArray new];
  for (CBCharacteristic *characteristic in service.characteristics) {
    if (![characteristic isKindOfClass:CBMutableCharacteristic.class])
      continue;
    NSString *key = [NSString stringWithFormat:@"%@:%@", svc, characteristic.UUID.UUIDString];
    g_tracked_characteristics[key] = (CBMutableCharacteristic *)characteristic;
    [charUUIDs addObject:characteristic.UUID.UUIDString];
  }
  g_tracked_services[svc] = charUUIDs;
  [g_lock unlock];
}

void simble_shadow_untrack_service(CBUUID *serviceUUID) {
  if (!serviceUUID)
    return;
  NSString *svc = serviceUUID.UUIDString;
  [g_lock lock];
  for (NSString *charUUID in g_tracked_services[svc]) {
    [g_tracked_characteristics removeObjectForKey:[NSString stringWithFormat:@"%@:%@", svc,
                                                                             charUUID]];
  }
  [g_tracked_services removeObjectForKey:svc];
  [g_lock unlock];
}

NSArray<NSString *> *simble_shadow_tracked_service_uuids(void) {
  [g_lock lock];
  NSArray<NSString *> *snapshot = g_tracked_services.allKeys;
  [g_lock unlock];
  return snapshot;
}

CBMutableCharacteristic *simble_shadow_tracked_characteristic(CBUUID *serviceUUID,
                                                              CBUUID *characteristicUUID) {
  if (!serviceUUID || !characteristicUUID)
    return nil;
  NSString *key =
      [NSString stringWithFormat:@"%@:%@", serviceUUID.UUIDString, characteristicUUID.UUIDString];
  [g_lock lock];
  CBMutableCharacteristic *characteristic = g_tracked_characteristics[key];
  [g_lock unlock];
  return characteristic;
}

CBCentral *simble_shadow_central(const uint8_t *centralId, size_t centralLen, size_t mtu) {
  if (!centralId || centralLen == 0)
    return nil;
  NSString *key = hexOf(centralId, centralLen);
  [g_lock lock];
  CBCentral *existing = g_centrals[key];
  if (existing) {
    [g_lock unlock];
    return existing;
  }
  CBCentral *minted = mintInstance(g_centralShadowClass);
  SimbleShadowMeta *meta = [SimbleShadowMeta new];
  meta.peripheralId = [NSData dataWithBytes:centralId length:centralLen];
  // A stable per-id UUID for the stand-in's identifier, derived from the id hex.
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:key];
  meta.identifier = uuid ?: [NSUUID UUID];
  meta.mtu = mtu;
  objc_setAssociatedObject(minted, kShadowMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  g_centrals[key] = minted;
  [g_minted addObject:ptr(minted)];
  [g_lock unlock];
  return minted;
}

BOOL simble_shadow_central_id(CBCentral *central, uint8_t *out, size_t cap, size_t *outLen) {
  if (!central)
    return NO;
  [g_lock lock];
  BOOL minted = [g_minted containsObject:ptr(central)];
  [g_lock unlock];
  if (!minted)
    return NO;
  NSData *cidData = metaOf(central).peripheralId;
  if (!cidData || (size_t)cidData.length > cap)
    return NO;
  memcpy(out, cidData.bytes, cidData.length);
  *outLen = cidData.length;
  return YES;
}

CBATTRequest *simble_shadow_att_request(uint64_t requestId, BOOL isWrite,
                                        CBCharacteristic *characteristic, CBCentral *central,
                                        NSUInteger offset, const uint8_t *value, size_t valueLen) {
  CBATTRequest *minted = mintInstance(g_attRequestShadowClass);
  SimbleShadowMeta *meta = [SimbleShadowMeta new];
  meta.requestId = requestId;
  meta.isWrite = isWrite;
  meta.characteristic = characteristic;
  meta.central = central;
  meta.offset = offset;
  meta.value = value ? [NSData dataWithBytes:value length:valueLen] : nil;
  objc_setAssociatedObject(minted, kShadowMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [g_lock lock];
  [g_minted addObject:ptr(minted)];
  [g_lock unlock];
  return minted;
}

BOOL simble_shadow_request_id(CBATTRequest *request, uint64_t *requestId, BOOL *isWrite) {
  if (!request)
    return NO;
  [g_lock lock];
  BOOL minted = [g_minted containsObject:ptr(request)];
  [g_lock unlock];
  if (!minted)
    return NO;
  SimbleShadowMeta *meta = metaOf(request);
  *requestId = meta.requestId;
  *isWrite = meta.isWrite;
  return YES;
}

void simble_shadow_reset(void) {
  [g_lock lock];
  [g_managers removeAllObjects];
  [g_peripherals removeAllObjects];
  [g_services removeAllObjects];
  [g_characteristics removeAllObjects];
  [g_minted removeAllObjects];
  [g_peripheral_managers removeAllObjects];
  [g_tracked_characteristics removeAllObjects];
  [g_tracked_services removeAllObjects];
  [g_centrals removeAllObjects];
  [g_lock unlock];
}
