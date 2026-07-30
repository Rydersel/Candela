// Private-API declarations.
//
// Per-framework strategy — new symbols must land in the right bucket:
//   * CoreDisplay-exported symbols (IOAVService*, CoreDisplay_*, and the
//     SkyLight/CGS symbols CoreDisplay re-exports) → plain `extern`
//     declarations here, resolved at link time via the one
//     `.linkedFramework("CoreDisplay")` in Package.swift. CoreDisplay lives in
//     /System/Library/Frameworks, so this is not a private-framework link.
//   * DisplayServices, MonitorPanel, SkyLight (and OSD, if ever adopted) →
//     NEVER linked. Resolve them at runtime with dlopen + dlsym (C functions:
//     see CandelaKit/Brightness/DisplayServicesShim.swift) or dlopen +
//     NSClassFromString messaged through an @objc protocol declared in this
//     target (Objective-C classes: see MonitorPanel.h). Spec §4 forbids
//     linker flags against private frameworks.
#ifndef CANDELA_PRIVATE_APIS_H
#define CANDELA_PRIVATE_APIS_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

// Objective-C protocol surface for dlopen'd frameworks (__OBJC__-guarded —
// shim.c compiles this umbrella header as plain C).
#include "MonitorPanel.h"

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

// Used by Arm64DDC.ioregMatchScore (exported by CoreDisplay, already linked).
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

// Used by IntelDDC.servicePortUsingDisplayPropertiesMatching (SkyLight/CGS private symbol).
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

#endif
