// include/MonitorPanel.h — private MonitorPanel.framework interfaces.
// Loaded via dlopen + NSClassFromString at runtime; never linked.
//
// The MonitorPanel protocol declarations were identified from MonitorControl's
// bridging header (MIT), Support/Bridging-Header.h:29-41. They describe Apple's
// private framework interface and can only be written one way; the surrounding
// shim is Candela's own.
//
// Do not add selectors that are not verified to exist; void-returning
// undeclared selectors crash through perform().
//
// Instances are messaged through these protocols via unsafeBitCast, which is
// only valid because they are @objc protocols (single refcounted pointer
// layout). Never restate them as native Swift protocols.
#ifndef CANDELA_MONITORPANEL_H
#define CANDELA_MONITORPANEL_H
#ifdef __OBJC__
#import <Foundation/Foundation.h>

@protocol MPDisplay <NSObject>
@property(readonly) unsigned int displayID;
@property(readonly) BOOL isBuiltIn;
@property(readonly) BOOL hasHDRModes;
@property BOOL preferHDRModes;
- (NSString *)displayName;
@end

@protocol MPDisplayMgr <NSObject>
- (NSArray *)displays;
- (BOOL)tryLockAccess;
- (void)unlockAccess;
@end

#endif /* __OBJC__ */
#endif
