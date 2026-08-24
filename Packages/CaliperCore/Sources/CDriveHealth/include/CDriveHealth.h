//
//  CDriveHealth.h
//  Caliper
//
//  Public NVMe SMART API, which the IOKit Swift module does not export, reached
//  through a C shim rather than by driving the plug-in's COM vtable from Swift.
//
//  Separate from `CPrivateShims` on purpose: nothing here is private API, so it
//  carries none of that target's risk of disappearing in a macOS update.
//

#ifndef CDRIVE_HEALTH_H
#define CDRIVE_HEALTH_H

#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <stdbool.h>

/// Reads the internal drive's SMART log.
///
/// Returns false when no drive exposes the SMART user client — which is the
/// normal answer on machines whose storage is not an NVMe block device, and the
/// reason the drive-health feature is best-effort.
bool CaliperReadNVMeSMART(NVMeSMARTData *out);

#endif /* CDRIVE_HEALTH_H */
