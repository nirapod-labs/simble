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

// Identity attached to a minted peripheral, service, or characteristic. A minted object
// carries one of these as associated state; absence of it is what "not managed" means.
@interface SimbleShadowMeta : NSObject
@property(nonatomic, strong) NSData *peripheralId; // peripheral id (peripheral, service, char)
@property(nonatomic, strong, nullable) CBUUID *serviceUUID;        // service and characteristic
@property(nonatomic, strong, nullable) CBUUID *characteristicUUID; // characteristic only
@property(nonatomic, weak, nullable) CBCentralManager *owner;      // owning manager (peripheral)
@property(nonatomic, weak, nullable) CBPeripheral *peripheral;     // owning peripheral (service)
@property(nonatomic, strong, nullable)
    NSMutableArray *children; // attached services or characteristics
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

__attribute__((constructor)) static void simble_shadow_init(void) {
  g_lock = [NSLock new];
  g_managers = [NSMutableDictionary new];
  g_peripherals = [NSMutableDictionary new];
  g_services = [NSMutableDictionary new];
  g_characteristics = [NSMutableDictionary new];
  g_minted = [NSMutableSet new];
  g_peripheralShadowClass = makeShadowSubclass([CBPeripheral class], "SimbleShadowPeripheral");
  g_serviceShadowClass = makeShadowSubclass([CBService class], "SimbleShadowService");
  g_characteristicShadowClass =
      makeShadowSubclass([CBCharacteristic class], "SimbleShadowCharacteristic");
  // The stand-in peripheral's services and the stand-in service's characteristics answer from the
  // registry's attached child list.
  class_addMethod(g_peripheralShadowClass, sel_registerName("services"), (IMP)shadowChildren,
                  "@@:");
  class_addMethod(g_serviceShadowClass, sel_registerName("characteristics"), (IMP)shadowChildren,
                  "@@:");
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

void simble_shadow_reset(void) {
  [g_lock lock];
  [g_managers removeAllObjects];
  [g_peripherals removeAllObjects];
  [g_services removeAllObjects];
  [g_characteristics removeAllObjects];
  [g_minted removeAllObjects];
  [g_lock unlock];
}
