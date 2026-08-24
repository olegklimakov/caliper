#include "CDriveHealth.h"

#include <IOKit/IOKitLib.h>

bool CaliperReadNVMeSMART(NVMeSMARTData *out) {
    if (!out) {
        return false;
    }

    // The user client lives on the block storage device, not on the controller:
    // asking IONVMeController for it returns kIOReturnUnsupported.
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"));
    if (!service) {
        return false;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t created = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (created != KERN_SUCCESS || !plugin) {
        return false;
    }

    IONVMeSMARTInterface **interface = NULL;
    HRESULT queried = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&interface);

    bool ok = false;
    if (queried == S_OK && interface) {
        ok = (*interface)->SMARTReadData(interface, out) == kIOReturnSuccess;
        (*interface)->Release(interface);
    }
    IODestroyPlugInInterface(plugin);
    return ok;
}
