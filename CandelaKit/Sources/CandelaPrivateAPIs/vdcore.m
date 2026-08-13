// The ONLY translation unit that touches the private CGVirtualDisplay class
// family. Classes are resolved with NSClassFromString exclusively; a
// link-time reference to a private class is a dyld launch failure on any
// macOS that removes it, so the app build carries an `nm` check that no
// _OBJC_CLASS_$_CGVirtualDisplay* symbol reaches a binary.
//
// Interfaces are transcribed from the live ObjC runtime on macOS 26.6, not
// from community headers (tools/vdrig/src/vdrig.h documents the three places
// they disagree). The creation sequence is the rig holder's, measured working
// since 2026-08-04.
//
// Memory management is written to be correct under BOTH ARC and MRC: SwiftPM
// compiles C-family targets with the compiler default (MRC), and this file
// must not silently change behavior if that ever flips.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#if __has_feature(objc_arc)
#define VD_RELEASE_LOCAL(x)
#else
#define VD_RELEASE_LOCAL(x) [x release]
#endif

// Failure codes, mirrored by VirtualDisplayHost.
enum {
  kCandelaVDFailureUnavailable = 1,
  kCandelaVDFailureRefused = 2,
  kCandelaVDFailureIdentityInUse = 3,
  kCandelaVDFailureSettingsRejected = 4,
  kCandelaVDFailureNeverAppeared = 5,
};

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(retain, nonatomic) dispatch_queue_t queue;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@end

static BOOL CandelaVDDisplayIsOnline(CGDirectDisplayID want) {
  uint32_t count = 0;
  CGGetOnlineDisplayList(0, NULL, &count);
  if (count == 0) return NO;
  CGDirectDisplayID ids[count];
  CGGetOnlineDisplayList(count, ids, &count);
  for (uint32_t i = 0; i < count; i++) {
    if (ids[i] == want) return YES;
  }
  return NO;
}

// The displayID assignment and WindowServer arrival both need the creating
// thread's run loop pumped; a bare sleep never sees them (rig holder,
// measured).
static void CandelaVDPump(double seconds) {
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

bool CandelaVDAvailable(void) {
  return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
      && NSClassFromString(@"CGVirtualDisplay") != nil
      && NSClassFromString(@"CGVirtualDisplaySettings") != nil
      && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

void *CandelaVDCreate(const char *name, uint32_t vendorID, uint32_t productID,
                      uint32_t serialNum, double widthMm, double heightMm,
                      uint32_t maxPixelsWide, uint32_t maxPixelsHigh,
                      uint32_t logicalWidth, uint32_t logicalHeight,
                      bool hiDPI, double refreshHz, double appearanceTimeout,
                      uint32_t *outDisplayID, int *outFailure) {
  @autoreleasepool {
    if (outFailure) *outFailure = 0;
    if (outDisplayID) *outDisplayID = 0;

    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class vdCls = NSClassFromString(@"CGVirtualDisplay");
    Class setCls = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descCls || !vdCls || !setCls || !modeCls) {
      if (outFailure) *outFailure = kCandelaVDFailureUnavailable;
      return NULL;
    }

    CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
    dispatch_queue_t queue = dispatch_queue_create("com.rydersel.Candela.vd", DISPATCH_QUEUE_SERIAL);
    desc.queue = queue;
#if !__has_feature(objc_arc)
    dispatch_release(queue);
#endif
    desc.name = [NSString stringWithUTF8String:name ?: ""];
    desc.vendorID = vendorID;
    desc.productID = productID;
    desc.serialNum = serialNum;
    desc.maxPixelsWide = maxPixelsWide;
    desc.maxPixelsHigh = maxPixelsHigh;
    desc.sizeInMillimeters = CGSizeMake(widthMm, heightMm);
    // sRGB primaries, the rig's values; part of the advertised EDID, so fixed.
    desc.redPrimary = CGPointMake(0.640, 0.330);
    desc.greenPrimary = CGPointMake(0.300, 0.600);
    desc.bluePrimary = CGPointMake(0.150, 0.060);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);

    CGVirtualDisplay *vd = [[vdCls alloc] initWithDescriptor:desc];
    VD_RELEASE_LOCAL(desc);
    if (!vd) {
      if (outFailure) *outFailure = kCandelaVDFailureRefused;
      return NULL;
    }

    CGVirtualDisplaySettings *settings = [[setCls alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.rotation = 0;
    CGVirtualDisplayMode *mode = [[modeCls alloc] initWithWidth:logicalWidth
                                                         height:logicalHeight
                                                    refreshRate:refreshHz];
    settings.modes = @[ mode ];
    VD_RELEASE_LOCAL(mode);
    BOOL applied = [vd applySettings:settings];
    VD_RELEASE_LOCAL(settings);
    if (!applied) {
      VD_RELEASE_LOCAL(vd);
      if (outFailure) *outFailure = kCandelaVDFailureSettingsRejected;
      return NULL;
    }

    // Poll rather than judge the first read: a slow assignment is a race, a
    // standing zero is the API's duplicate-identity refusal, and the
    // difference matters.
    double waited = 0;
    while (vd.displayID == 0 && waited < 3.0) {
      CandelaVDPump(0.25);
      waited += 0.25;
    }
    if (vd.displayID == 0) {
      VD_RELEASE_LOCAL(vd);
      if (outFailure) *outFailure = kCandelaVDFailureIdentityInUse;
      return NULL;
    }

    CGDirectDisplayID displayID = vd.displayID;
    waited = 0;
    while (!CandelaVDDisplayIsOnline(displayID) && waited < appearanceTimeout) {
      CandelaVDPump(0.25);
      waited += 0.25;
    }
    if (!CandelaVDDisplayIsOnline(displayID)) {
      // Released before reporting: a half-created display is exactly the
      // thing later code would treat as live.
      VD_RELEASE_LOCAL(vd);
      if (outFailure) *outFailure = kCandelaVDFailureNeverAppeared;
      return NULL;
    }

    if (outDisplayID) *outDisplayID = displayID;
    void *token = (void *)CFBridgingRetain(vd);
    VD_RELEASE_LOCAL(vd); // token now holds the sole +1 under MRC too
    return token;
  }
}

bool CandelaVDDestroy(void *token, uint32_t displayID, double departureTimeout) {
  if (!token) return true;
  // The release gets its OWN pool, drained before the departure poll starts:
  // under MRC, CFBridgingRelease is an autorelease, and a pool that drains
  // after the poll would keep the display retained for the entire wait
  // (measured: destroy timed out at 10 s, then the display departed the
  // moment the pool drained).
  @autoreleasepool {
    CFBridgingRelease(token);
  }
  @autoreleasepool {
    double waited = 0;
    while (CandelaVDDisplayIsOnline(displayID) && waited < departureTimeout) {
      CandelaVDPump(0.25);
      waited += 0.25;
    }
    return !CandelaVDDisplayIsOnline(displayID);
  }
}
