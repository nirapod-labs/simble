/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file peripheral_hooks.m
 * @brief The peripheral swizzle set: CBPeripheralManager interception.
 *
 * @details
 * The guest's GATT-server calls route to the host helper, and the host's peripheral events come
 * back as the guest's own CBPeripheralManagerDelegate callbacks, dispatched on the queue the guest
 * gave its manager. A call whose receiver the registry did not register passes through to the saved
 * original implementation, so a non-managed CoreBluetooth user is byte-for-byte unaffected. No key
 * material, pairing secret, or bonding record crosses the interposer: only GATT operations and byte
 * payloads do.
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

// Dispatch a block on the manager's queue, the main queue when it gave none.
static void dispatchOnPeripheralQueue(SimblePeripheralManagerEntry *entry, dispatch_block_t block) {
  dispatch_queue_t queue = entry.queue ?: dispatch_get_main_queue();
  dispatch_async(queue, block);
}

// --- The peripheral event stream: one reader thread, started on the first managed init ---

// The reader loop: drain the event connection, deliver each peripheral event, exit on close.
static void runPeripheralEventReader(void) {
  simble_conn conn;
  if (simble_client_open(&conn) != SIMBLE_OK)
    return;
  for (;;) {
    simble_event event;
    if (simble_client_read_event(&conn, &event) != SIMBLE_OK)
      break;
    simble_deliver_peripheral_event(&event);
  }
  simble_client_close(&conn);
}

// Start the peripheral event reader once per process, on the first managed manager.
static void startPeripheralEventReaderOnce(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      runPeripheralEventReader();
    });
  });
}

// --- Extraction helpers ---

// Build parallel UUID, properties, and permissions arrays from a service's mutable characteristics.
// Returns the count; the NSArrays hold the UUID strings so the encoder reads stable pointers, and
// the caller frees the three malloc'd arrays.
static size_t buildCharacteristics(CBMutableService *service, NSMutableArray<NSString *> *held,
                                   const char ***uuidsOut, size_t **lensOut, uint64_t **propsOut,
                                   uint64_t **permsOut) {
  size_t count = service.characteristics.count;
  if (count == 0) {
    *uuidsOut = NULL;
    *lensOut = NULL;
    *propsOut = NULL;
    *permsOut = NULL;
    return 0;
  }
  const char **uuids = calloc(count, sizeof(char *));
  size_t *lens = calloc(count, sizeof(size_t));
  uint64_t *props = calloc(count, sizeof(uint64_t));
  uint64_t *perms = calloc(count, sizeof(uint64_t));
  size_t i = 0;
  for (CBCharacteristic *c in service.characteristics) {
    NSString *s = c.UUID.UUIDString;
    [held addObject:s];
    uuids[i] = s.UTF8String;
    lens[i] = strlen(uuids[i]);
    props[i] = (uint64_t)c.properties;
    perms[i] = [c isKindOfClass:CBMutableCharacteristic.class]
                   ? (uint64_t)((CBMutableCharacteristic *)c).permissions
                   : 0;
    i++;
  }
  *uuidsOut = uuids;
  *lensOut = lens;
  *propsOut = props;
  *permsOut = perms;
  return count;
}

// --- CBPeripheralManager routed methods ---

@interface CBPeripheralManager (SimblePeripheral)
@end

@implementation CBPeripheralManager (SimblePeripheral)

// Register the manager with its delegate and queue, then return the manager the original built.
- (instancetype)simble_initWithDelegate:(id<CBPeripheralManagerDelegate>)delegate
                                  queue:(dispatch_queue_t)queue {
  CBPeripheralManager *manager = [self simble_initWithDelegate:delegate queue:queue];
  if (manager) {
    simble_shadow_register_peripheral_manager(manager, delegate, queue);
    startPeripheralEventReaderOnce();
    SimblePeripheralManagerEntry *entry = simble_shadow_peripheral_manager_entry();
    // Mirror CoreBluetooth's async first state update: peripheralManagerDidUpdateState: on the
    // manager's queue.
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> d = entry.delegate;
      if ([d respondsToSelector:@selector(peripheralManagerDidUpdateState:)]) {
        [d peripheralManagerDidUpdateState:manager];
      }
    });
  }
  return manager;
}

- (instancetype)simble_initWithDelegate:(id<CBPeripheralManagerDelegate>)delegate
                                  queue:(dispatch_queue_t)queue
                                options:(NSDictionary<NSString *, id> *)options {
  CBPeripheralManager *manager = [self simble_initWithDelegate:delegate queue:queue options:options];
  if (manager) {
    simble_shadow_register_peripheral_manager(manager, delegate, queue);
    startPeripheralEventReaderOnce();
    SimblePeripheralManagerEntry *entry = simble_shadow_peripheral_manager_entry();
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> d = entry.delegate;
      if ([d respondsToSelector:@selector(peripheralManagerDidUpdateState:)]) {
        [d peripheralManagerDidUpdateState:manager];
      }
    });
  }
  return manager;
}

- (void)simble_addService:(CBMutableService *)service {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    [self simble_addService:service];
    return;
  }
  // Route ADD_SERVICE, track the service so its characteristics resolve on later events, and
  // deliver peripheralManager:didAddService:error:.
  simble_shadow_track_service(service);
  const char *svc = service.UUID.UUIDString.UTF8String;
  NSMutableArray<NSString *> *held = [NSMutableArray array];
  const char **uuids = NULL;
  size_t *lens = NULL;
  uint64_t *props = NULL;
  uint64_t *perms = NULL;
  size_t count = buildCharacteristics(service, held, &uuids, &lens, &props, &perms);
  simble_response resp;
  simble_status st = simble_client_add_service(svc, strlen(svc), service.isPrimary ? 1 : 0, uuids,
                                               lens, props, perms, count, &resp);
  free(uuids);
  free(lens);
  free(props);
  free(perms);
  simble_internal_stats()->add_service++;
  SimblePeripheralManagerEntry *entry = simble_shadow_peripheral_manager_entry();
  CBPeripheralManager *manager = self;
  dispatchOnPeripheralQueue(entry, ^{
    id<CBPeripheralManagerDelegate> delegate = entry.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_SERVICE)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain code:resp.error_code userInfo:nil];
    if ([delegate respondsToSelector:@selector(peripheralManager:didAddService:error:)]) {
      [delegate peripheralManager:manager didAddService:service error:error];
    }
  });
}

- (void)simble_removeService:(CBMutableService *)service {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    [self simble_removeService:service];
    return;
  }
  simble_shadow_untrack_service(service.UUID);
  const char *svc = service.UUID.UUIDString.UTF8String;
  simble_response resp;
  simble_client_remove_service(svc, strlen(svc), &resp);
  simble_internal_stats()->remove_service++;
}

- (void)simble_removeAllServices {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    [self simble_removeAllServices];
    return;
  }
  // Route a REMOVE_SERVICE for each tracked service, then drop the local tracking.
  for (NSString *uuid in simble_shadow_tracked_service_uuids()) {
    const char *svc = uuid.UTF8String;
    simble_response resp;
    simble_client_remove_service(svc, strlen(svc), &resp);
    simble_shadow_untrack_service([CBUUID UUIDWithString:uuid]);
    simble_internal_stats()->remove_service++;
  }
}

- (void)simble_startAdvertising:(NSDictionary<NSString *, id> *)advertisementData {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    [self simble_startAdvertising:advertisementData];
    return;
  }
  // Route START_ADVERTISING with the local name and service UUIDs, then deliver
  // peripheralManagerDidStartAdvertising:error:.
  NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey];
  const char *name = [localName isKindOfClass:NSString.class] ? localName.UTF8String : NULL;
  NSArray<CBUUID *> *serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
  size_t count = [serviceUUIDs isKindOfClass:NSArray.class] ? serviceUUIDs.count : 0;
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
  simble_status st =
      simble_client_start_advertising(name, name ? strlen(name) : 0, uuids, lens, count, &resp);
  free(uuids);
  free(lens);
  simble_internal_stats()->start_advertising++;
  SimblePeripheralManagerEntry *entry = simble_shadow_peripheral_manager_entry();
  CBPeripheralManager *manager = self;
  dispatchOnPeripheralQueue(entry, ^{
    id<CBPeripheralManagerDelegate> delegate = entry.delegate;
    NSError *error = (st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED)
                         ? nil
                         : [NSError errorWithDomain:CBErrorDomain code:resp.error_code userInfo:nil];
    if ([delegate respondsToSelector:@selector(peripheralManagerDidStartAdvertising:error:)]) {
      [delegate peripheralManagerDidStartAdvertising:manager error:error];
    }
  });
}

- (void)simble_stopAdvertising {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    [self simble_stopAdvertising];
    return;
  }
  simble_response resp;
  simble_client_stop_advertising(&resp);
}

- (void)simble_respondToRequest:(CBATTRequest *)request withResult:(CBATTError)result {
  uint64_t requestId = 0;
  BOOL isWrite = NO;
  if (!simble_shadow_request_id(request, &requestId, &isWrite)) {
    [self simble_respondToRequest:request withResult:result];
    return;
  }
  // A read answer carries the value the guest set on the request; a write answer carries none.
  simble_response resp;
  if (isWrite) {
    simble_client_respond_write(requestId, (uint64_t)result, &resp);
  } else {
    NSData *value = request.value;
    simble_client_respond_read(requestId, value.bytes, value.length, (uint64_t)result, &resp);
  }
  simble_internal_stats()->respond++;
}

- (BOOL)simble_updateValue:(NSData *)value
         forCharacteristic:(CBMutableCharacteristic *)characteristic
      onSubscribedCentrals:(NSArray<CBCentral *> *)centrals {
  if (!simble_shadow_is_managed_peripheral_manager(self)) {
    return [self simble_updateValue:value forCharacteristic:characteristic onSubscribedCentrals:centrals];
  }
  // Resolve the service UUID from the characteristic's service, and the target central from the
  // first entry when one is named.
  CBUUID *serviceUUID = characteristic.service.UUID;
  const char *svc = serviceUUID.UUIDString.UTF8String;
  const char *chr = characteristic.UUID.UUIDString.UTF8String;
  uint8_t cid[64];
  size_t cidLen = 0;
  const uint8_t *central = NULL;
  if (centrals.count && simble_shadow_central_id(centrals.firstObject, cid, sizeof(cid), &cidLen)) {
    central = cid;
  }
  simble_response resp;
  simble_status st = simble_client_update_value(svc, svc ? strlen(svc) : 0, chr, chr ? strlen(chr) : 0,
                                                value.bytes, value.length, central, cidLen, &resp);
  simble_internal_stats()->update_value++;
  return st == SIMBLE_OK && resp.kind == SIMBLE_RESP_CONFIRMED;
}

// A managed peripheral manager reports poweredOn: the host serves only after its radio powers on,
// so a reachable bridge means the host peripheral is powered on.
- (CBManagerState)simble_peripheral_state {
  if (simble_shadow_is_managed_peripheral_manager(self))
    return CBManagerStatePoweredOn;
  return [self simble_peripheral_state];
}

@end

// --- Peripheral event delivery ---

void simble_deliver_peripheral_event(const simble_event *event) {
  SimblePeripheralManagerEntry *entry = simble_shadow_peripheral_manager_entry();
  if (!entry)
    return;
  CBPeripheralManager *manager = entry.manager;

  switch (event->kind) {
  case SIMBLE_EVT_PERIPHERAL_STATE_CHANGED: {
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> delegate = entry.delegate;
      if ([delegate respondsToSelector:@selector(peripheralManagerDidUpdateState:)]) {
        [delegate peripheralManagerDidUpdateState:manager];
      }
    });
    simble_internal_stats()->peripheral_event++;
    break;
  }
  case SIMBLE_EVT_READ_REQUEST:
  case SIMBLE_EVT_WRITE_REQUEST: {
    BOOL isWrite = event->kind == SIMBLE_EVT_WRITE_REQUEST;
    CBUUID *serviceUUID = [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->service]];
    CBUUID *charUUID =
        [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->characteristic]];
    CBCharacteristic *characteristic = simble_shadow_tracked_characteristic(serviceUUID, charUUID);
    CBCentral *central = simble_shadow_central(event->central, event->central_len, 0);
    CBATTRequest *request = simble_shadow_att_request(
        event->request_id, isWrite, characteristic, central, (NSUInteger)event->att_offset,
        isWrite ? event->value : NULL, isWrite ? event->value_len : 0);
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> delegate = entry.delegate;
      if (isWrite) {
        if ([delegate respondsToSelector:@selector(peripheralManager:didReceiveWriteRequests:)]) {
          [delegate peripheralManager:manager didReceiveWriteRequests:@[ request ]];
        }
      } else if ([delegate respondsToSelector:@selector(peripheralManager:didReceiveReadRequest:)]) {
        [delegate peripheralManager:manager didReceiveReadRequest:request];
      }
    });
    simble_internal_stats()->peripheral_event++;
    break;
  }
  case SIMBLE_EVT_SUBSCRIBED:
  case SIMBLE_EVT_UNSUBSCRIBED: {
    BOOL subscribed = event->kind == SIMBLE_EVT_SUBSCRIBED;
    CBUUID *serviceUUID = [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->service]];
    CBUUID *charUUID =
        [CBUUID UUIDWithString:[NSString stringWithUTF8String:event->characteristic]];
    CBCharacteristic *characteristic = simble_shadow_tracked_characteristic(serviceUUID, charUUID);
    CBCentral *central =
        simble_shadow_central(event->central, event->central_len, (size_t)event->mtu);
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> delegate = entry.delegate;
      if (subscribed) {
        if ([delegate respondsToSelector:@selector
                      (peripheralManager:central:didSubscribeToCharacteristic:)]) {
          [delegate peripheralManager:manager
                              central:central
            didSubscribeToCharacteristic:characteristic];
        }
      } else if ([delegate respondsToSelector:@selector
                           (peripheralManager:central:didUnsubscribeFromCharacteristic:)]) {
        [delegate peripheralManager:manager
                            central:central
          didUnsubscribeFromCharacteristic:characteristic];
      }
    });
    simble_internal_stats()->peripheral_event++;
    break;
  }
  case SIMBLE_EVT_READY_TO_UPDATE: {
    dispatchOnPeripheralQueue(entry, ^{
      id<CBPeripheralManagerDelegate> delegate = entry.delegate;
      if ([delegate respondsToSelector:@selector(peripheralManagerIsReadyToUpdateSubscribers:)]) {
        [delegate peripheralManagerIsReadyToUpdateSubscribers:manager];
      }
    });
    simble_internal_stats()->peripheral_event++;
    break;
  }
  default:
    break;
  }
}

// `state` is inherited from the shared CBManager superclass; this calls the superclass state,
// installed on CBPeripheralManager so the swizzle stays on the peripheral class.
static CBManagerState simble_peripheral_state_super(id self, SEL _cmd) {
  (void)_cmd;
  struct objc_super sup = {self, [CBPeripheralManager superclass]};
  CBManagerState (*send)(struct objc_super *, SEL) =
      (CBManagerState(*)(struct objc_super *, SEL))objc_msgSendSuper;
  return send(&sup, @selector(state));
}

int simble_install_peripheral_hooks(void) {
  int failures = 0;
  Class managerClass = [CBPeripheralManager class];
  class_addMethod(managerClass, @selector(state), (IMP)simble_peripheral_state_super, "q@:");
  failures += simble_swizzle(managerClass, @selector(state), @selector(simble_peripheral_state));
  failures += simble_swizzle(managerClass, @selector(initWithDelegate:queue:),
                             @selector(simble_initWithDelegate:queue:));
  failures += simble_swizzle(managerClass, @selector(initWithDelegate:queue:options:),
                             @selector(simble_initWithDelegate:queue:options:));
  failures += simble_swizzle(managerClass, @selector(addService:), @selector(simble_addService:));
  failures +=
      simble_swizzle(managerClass, @selector(removeService:), @selector(simble_removeService:));
  failures += simble_swizzle(managerClass, @selector(removeAllServices),
                             @selector(simble_removeAllServices));
  failures += simble_swizzle(managerClass, @selector(startAdvertising:),
                             @selector(simble_startAdvertising:));
  failures +=
      simble_swizzle(managerClass, @selector(stopAdvertising), @selector(simble_stopAdvertising));
  failures += simble_swizzle(managerClass, @selector(respondToRequest:withResult:),
                             @selector(simble_respondToRequest:withResult:));
  failures += simble_swizzle(managerClass,
                             @selector(updateValue:forCharacteristic:onSubscribedCentrals:),
                             @selector(simble_updateValue:forCharacteristic:onSubscribedCentrals:));
  return failures;
}
