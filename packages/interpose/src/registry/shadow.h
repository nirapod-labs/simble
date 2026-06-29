/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Nirapod Labs
 */

/**
 * @file shadow.h
 * @brief The shadow registry: the managers, peripherals, services, and characteristics
 *        the interposer mints to stand in for the host's CoreBluetooth objects.
 *
 * @details
 * CoreBluetooth's CBPeripheral, CBService, and CBCharacteristic are opaque and cannot
 * be constructed by an app, so the interposer mints stand-ins keyed by the host
 * identifier and hands them to the guest's delegate. The registry is the one map from
 * a stand-in back to its host identity. It fails closed: a routing path that receives
 * an object the registry did not mint treats it as not managed and passes it through.
 *
 * A CBCentralManager the guest creates while the interposer is active is registered
 * here too, with the delegate and dispatch queue it was given, so a host event becomes
 * a delegate callback dispatched on that queue.
 *
 * All functions are safe to call from any thread; the tables are guarded by one
 * internal lock.
 *
 * @author Nirapod Labs
 * @date 2026
 */

#ifndef SIMBLE_SHADOW_H
#define SIMBLE_SHADOW_H

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * @defgroup simble_shadow Shadow registry
 * @brief Minting and lookup of the stand-in CoreBluetooth objects.
 * @{
 */

/// A registered central manager: the delegate to call back and the queue to call it on.
@interface SimbleManagerEntry : NSObject
/// The delegate the guest passed to initWithDelegate:queue:, weakly held as CoreBluetooth does.
@property(nonatomic, weak, nullable) id<CBCentralManagerDelegate> delegate;
/// The dispatch queue the guest gave its manager; nil means the main queue, as CoreBluetooth does.
@property(nonatomic, strong, nullable) dispatch_queue_t queue;
@end

/**
 * @brief Register a CBCentralManager the guest created while the interposer is active.
 *
 * @param[in] manager  The manager instance.
 * @param[in] delegate The delegate it was created with, or nil.
 * @param[in] queue    The dispatch queue it was created with, or nil for the main queue.
 */
void simble_shadow_register_manager(CBCentralManager *manager,
                                    id<CBCentralManagerDelegate> _Nullable delegate,
                                    dispatch_queue_t _Nullable queue);

/**
 * @brief Whether a CBCentralManager is one the interposer manages.
 *
 * @param[in] manager The manager to test.
 * @return YES if registered, NO otherwise.
 */
BOOL simble_shadow_is_managed_manager(CBCentralManager *manager);

/**
 * @brief The registration for a managed manager, or nil if it is not managed.
 *
 * @param[in] manager The manager to look up.
 * @return The entry, or nil.
 */
SimbleManagerEntry *_Nullable simble_shadow_manager_entry(CBCentralManager *manager);

/**
 * @brief Mint or return the stand-in peripheral for a host identifier under a manager.
 *
 * The first call for an identifier mints a CBPeripheral stand-in and records it; a later
 * call for the same identifier returns the same stand-in.
 *
 * @param[in] manager        The owning managed manager.
 * @param[in] peripheralId   The host CBPeripheral.identifier bytes.
 * @param[in] peripheralLen  Length of @p peripheralId.
 * @return The stand-in peripheral, or nil if the identifier was empty or @p manager is not managed.
 */
CBPeripheral *_Nullable simble_shadow_peripheral(CBCentralManager *manager,
                                                 const uint8_t *peripheralId, size_t peripheralLen);

/**
 * @brief Whether a CBPeripheral is one the interposer minted.
 *
 * @param[in] peripheral The peripheral to test.
 * @return YES if minted here, NO otherwise.
 */
BOOL simble_shadow_is_managed_peripheral(CBPeripheral *peripheral);

/**
 * @brief Copy the host identifier bytes of a minted peripheral.
 *
 * @param[in]  peripheral The minted peripheral.
 * @param[out] out        Buffer the identifier is copied into.
 * @param[in]  cap        Capacity of @p out.
 * @param[out] outLen     Bytes written to @p out.
 * @return YES on a hit, NO if @p peripheral was not minted here or @p cap is too small.
 */
BOOL simble_shadow_peripheral_id(CBPeripheral *peripheral, uint8_t *out, size_t cap,
                                 size_t *outLen);

/**
 * @brief The managed manager that owns a minted peripheral, or nil.
 *
 * @param[in] peripheral The minted peripheral.
 * @return The owning manager, or nil if @p peripheral was not minted here.
 */
CBCentralManager *_Nullable simble_shadow_owner(CBPeripheral *peripheral);

/**
 * @brief Mint or return the stand-in service for a UUID on a minted peripheral.
 *
 * @param[in] peripheral  The minted peripheral.
 * @param[in] serviceUUID The service CBUUID.
 * @return The stand-in service, or nil if @p peripheral was not minted here.
 */
CBService *_Nullable simble_shadow_service(CBPeripheral *peripheral, CBUUID *serviceUUID);

/**
 * @brief Mint or return the stand-in characteristic for a UUID on a minted service.
 *
 * @param[in] service          The minted service.
 * @param[in] characteristicUUID The characteristic CBUUID.
 * @return The stand-in characteristic, or nil if @p service was not minted here.
 */
CBCharacteristic *_Nullable simble_shadow_characteristic(CBService *service,
                                                         CBUUID *characteristicUUID);

/**
 * @brief Resolve a minted service to its peripheral id and service UUID, so a discovery on it can
 *        be routed by host identity.
 *
 * @param[in]  service       The minted service.
 * @param[out] peripheralOut Buffer the peripheral id is copied into.
 * @param[in]  peripheralCap Capacity of @p peripheralOut.
 * @param[out] peripheralLen Bytes written to @p peripheralOut.
 * @param[out] serviceUUID   Set to the service CBUUID.
 * @return YES on a hit, NO if @p service was not minted here.
 */
BOOL simble_shadow_resolve_service(CBService *service, uint8_t *peripheralOut, size_t peripheralCap,
                                   size_t *peripheralLen, CBUUID *_Nullable *_Nonnull serviceUUID);

/**
 * @brief Resolve a minted characteristic to its peripheral id, service UUID, and characteristic
 *        UUID, so an operation on it can be routed by host identity.
 *
 * @param[in]  characteristic The minted characteristic.
 * @param[out] peripheralOut  Buffer the peripheral id is copied into.
 * @param[in]  peripheralCap  Capacity of @p peripheralOut.
 * @param[out] peripheralLen  Bytes written to @p peripheralOut.
 * @param[out] serviceUUID    Set to the service CBUUID.
 * @param[out] characteristicUUID Set to the characteristic CBUUID.
 * @return YES on a hit, NO if @p characteristic was not minted here.
 */
BOOL simble_shadow_resolve_characteristic(CBCharacteristic *characteristic, uint8_t *peripheralOut,
                                          size_t peripheralCap, size_t *peripheralLen,
                                          CBUUID *_Nullable *_Nonnull serviceUUID,
                                          CBUUID *_Nullable *_Nonnull characteristicUUID);

/// A registered peripheral manager: the manager to pass back, its delegate, and the queue.
@interface SimblePeripheralManagerEntry : NSObject
/// The manager the guest created, weakly held, passed as the first delegate-callback argument.
@property(nonatomic, weak, nullable) CBPeripheralManager *manager;
/// The delegate the guest passed to initWithDelegate:queue:, weakly held as CoreBluetooth does.
@property(nonatomic, weak, nullable) id<CBPeripheralManagerDelegate> delegate;
/// The dispatch queue the guest gave its manager; nil means the main queue, as CoreBluetooth does.
@property(nonatomic, strong, nullable) dispatch_queue_t queue;
@end

/**
 * @brief Register a CBPeripheralManager the guest created while the interposer is active.
 *
 * @param[in] manager  The manager instance.
 * @param[in] delegate The delegate it was created with, or nil.
 * @param[in] queue    The dispatch queue it was created with, or nil for the main queue.
 */
void simble_shadow_register_peripheral_manager(CBPeripheralManager *manager,
                                               id<CBPeripheralManagerDelegate> _Nullable delegate,
                                               dispatch_queue_t _Nullable queue);

/**
 * @brief Whether a CBPeripheralManager is one the interposer manages.
 *
 * @param[in] manager The manager to test.
 * @return YES if registered, NO otherwise.
 */
BOOL simble_shadow_is_managed_peripheral_manager(CBPeripheralManager *manager);

/**
 * @brief The sole registered peripheral manager, or nil if none is registered.
 *
 * The peripheral GATT database is process-wide, so events carry no manager and resolve to the one
 * registered manager.
 *
 * @return The entry, or nil.
 */
SimblePeripheralManagerEntry *_Nullable simble_shadow_peripheral_manager_entry(void);

/**
 * @brief Record a CBMutableService and its characteristics, keyed by UUID.
 *
 * A later event carrying a service and characteristic UUID resolves back to the guest's own
 * CBMutableCharacteristic through this record.
 *
 * @param[in] service The service the guest passed to addService:.
 */
void simble_shadow_track_service(CBMutableService *service);

/**
 * @brief Drop a tracked service and its characteristics.
 *
 * @param[in] serviceUUID The service UUID to drop.
 */
void simble_shadow_untrack_service(CBUUID *serviceUUID);

/**
 * @brief The UUID strings of every tracked service.
 *
 * @return A snapshot array of the tracked service UUID strings.
 */
NSArray<NSString *> *simble_shadow_tracked_service_uuids(void);

/**
 * @brief The tracked characteristic for a service and characteristic UUID, or nil.
 *
 * @param[in] serviceUUID        The service UUID.
 * @param[in] characteristicUUID The characteristic UUID.
 * @return The guest's CBMutableCharacteristic, or nil if it was never tracked.
 */
CBMutableCharacteristic *_Nullable simble_shadow_tracked_characteristic(CBUUID *serviceUUID,
                                                                        CBUUID *characteristicUUID);

/**
 * @brief Mint or return the stand-in central for a host identifier.
 *
 * The first call for an identifier mints a CBCentral stand-in and records it; a later call for the
 * same identifier returns the same stand-in.
 *
 * @param[in] centralId  The host central identifier bytes.
 * @param[in] centralLen Length of @p centralId.
 * @param[in] mtu        The central's maximumUpdateValueLength.
 * @return The stand-in central, or nil if the identifier was empty.
 */
CBCentral *_Nullable simble_shadow_central(const uint8_t *centralId, size_t centralLen, size_t mtu);

/**
 * @brief Copy the host identifier bytes of a minted central.
 *
 * @param[in]  central The minted central.
 * @param[out] out     Buffer the identifier is copied into.
 * @param[in]  cap     Capacity of @p out.
 * @param[out] outLen  Bytes written to @p out.
 * @return YES on a hit, NO if @p central was not minted here or @p cap is too small.
 */
BOOL simble_shadow_central_id(CBCentral *central, uint8_t *out, size_t cap, size_t *outLen);

/**
 * @brief Mint a stand-in ATT request carrying its request id, characteristic, and central.
 *
 * The guest answers the request by calling respondToRequest:withResult: on the stand-in, which
 * carries the request id back through ::simble_shadow_request_id.
 *
 * @param[in] requestId      The request id from the READ_REQUEST or WRITE_REQUEST event.
 * @param[in] isWrite        Non-zero for a write request.
 * @param[in] characteristic The guest's tracked characteristic for the request.
 * @param[in] central        The stand-in central that originated the request.
 * @param[in] offset         The ATT offset.
 * @param[in] value          The write value bytes, or NULL for a read.
 * @param[in] valueLen       Length of @p value; 0 for a read.
 * @return The stand-in request.
 */
CBATTRequest *simble_shadow_att_request(uint64_t requestId, BOOL isWrite,
                                        CBCharacteristic *_Nullable characteristic,
                                        CBCentral *_Nullable central, NSUInteger offset,
                                        const uint8_t *_Nullable value, size_t valueLen);

/**
 * @brief Resolve a minted ATT request to its request id and whether it was a write.
 *
 * @param[in]  request   The minted request.
 * @param[out] requestId Set to the request id.
 * @param[out] isWrite   Set to non-zero for a write request.
 * @return YES on a hit, NO if @p request was not minted here.
 */
BOOL simble_shadow_request_id(CBATTRequest *request, uint64_t *requestId, BOOL *isWrite);

/**
 * @brief Drop every registration.
 *
 * Returns the registry to its empty state. Used by tests between cases.
 */
void simble_shadow_reset(void);

/** @} */

NS_ASSUME_NONNULL_END

#endif
