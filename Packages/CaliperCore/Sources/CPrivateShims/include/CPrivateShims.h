//
//  CPrivateShims.h
//  Caliper
//
//  Declarations for the two private interfaces Caliper depends on:
//  IOHIDEventSystemClient (temperature sensors) and the AppleSMC user client
//  (fan RPM, read-only). Keeping them in a single header confines the whole
//  private-API risk surface: if Apple changes either interface, only this file
//  and its two Swift samplers are affected, and both degrade to unavailable
//  rather than crashing.
//
//  Caliper never writes to the SMC.
//

#ifndef CPRIVATE_SHIMS_H
#define CPRIVATE_SHIMS_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

#pragma mark - IOHIDEventSystemClient (temperature sensors)

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

/// Usage page/usage pair that matches Apple's on-board sensors.
static const int32_t kCaliperHIDPageAppleVendor = 0xff00;
static const int32_t kCaliperHIDUsageTemperature = 0x0005;

/// `IOHIDEventType` value for temperature events.
static const int64_t kCaliperHIDEventTypeTemperature = 15;

/// Field selector for the primary value of an event of the given type.
static inline int32_t CaliperHIDEventFieldBase(int64_t type) {
    return (int32_t)(type << 16);
}

/// Keys of the matching dictionary that selects sensor services.
static CFStringRef const kCaliperHIDPrimaryUsagePageKey = CFSTR("PrimaryUsagePage");
static CFStringRef const kCaliperHIDPrimaryUsageKey = CFSTR("PrimaryUsage");
/// Human-readable sensor name, e.g. "PMU tdie1".
static CFStringRef const kCaliperHIDProductKey = CFSTR("Product");
/// Stable identity of a sensor: the four-character SMC key, packed into an
/// integer. Several service clients report the same physical sensor, and this
/// is what tells them apart.
static CFStringRef const kCaliperHIDLocationIDKey = CFSTR("LocationID");

/// These follow the Core Foundation create/copy rule, but nothing in the name
/// of a hand-declared function tells Swift that. Without the annotations ARC
/// would either leak every reading or, worse, guess differently across
/// compiler versions.
extern IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;

extern void
IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client,
                                  CFDictionaryRef _Nullable matching);

extern CFArrayRef _Nullable
IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client) CF_RETURNS_RETAINED;

extern CFTypeRef _Nullable
IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property)
    CF_RETURNS_RETAINED;

extern IOHIDEventRef _Nullable
IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                            int64_t type,
                            int32_t options,
                            int64_t timestamp) CF_RETURNS_RETAINED;

extern double
IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#pragma mark - AppleSMC user client (fans, read-only)

/// Selectors of `AppleSMCUserClient`.
enum {
    kCaliperSMCUserClientOpen = 0,
    kCaliperSMCUserClientClose = 1,
    kCaliperSMCHandleYPCEvent = 2
};

/// `data8` command codes accepted by `kCaliperSMCHandleYPCEvent`.
enum {
    kCaliperSMCCmdReadBytes = 5,
    kCaliperSMCCmdReadIndex = 8,
    kCaliperSMCCmdReadKeyInfo = 9
};

typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    uint16_t release;
} CaliperSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} CaliperSMCPLimitData;

/// `IOByteCount32`, not `IOByteCount`: the user client expects a 32-bit size,
/// and on arm64 `IOByteCount` is 64-bit, which would push `CaliperSMCParamStruct`
/// to 88 bytes and make every `IOConnectCallStructMethod` fail.
typedef struct {
    IOByteCount32 dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CaliperSMCKeyInfoData;

/// Input and output struct of `IOConnectCallStructMethod` for the SMC.
typedef struct {
    uint32_t key;
    CaliperSMCVersion vers;
    CaliperSMCPLimitData pLimitData;
    CaliperSMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} CaliperSMCParamStruct;

/// The layout is a wire format: a mismatch means every SMC call fails at
/// runtime, which the graceful-degradation policy would silently hide.
_Static_assert(sizeof(CaliperSMCParamStruct) == 80,
               "CaliperSMCParamStruct must match the AppleSMC wire layout");

CF_ASSUME_NONNULL_END

#endif /* CPRIVATE_SHIMS_H */
