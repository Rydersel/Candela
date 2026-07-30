// Private-API declarations. Milestone 1 needs only the IOAVService DDC path
// (symbols exported by CoreDisplay.framework — link verified 2026-07-29).
#ifndef CANDELA_PRIVATE_APIS_H
#define CANDELA_PRIVATE_APIS_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

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
