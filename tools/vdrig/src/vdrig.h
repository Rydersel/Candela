// Shared declarations for the Candela virtual-display rig.
//
// The CGVirtualDisplay* interfaces below are transcribed from the live ObjC
// runtime on macOS 26.6 (build 25G72, arm64), NOT from community headers,
// which disagree with the system in three places: `hiDPI` and `rotation` are
// unsigned int rather than BOOL, `applySettings:` returns BOOL, and
// `CGVirtualDisplay.hiDPI` reads back as 2 regardless of what was assigned.

#ifndef CANDELA_VDRIG_H
#define CANDELA_VDRIG_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) double refreshDeadline;
@property(nonatomic) BOOL isReference;
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(readonly, nonatomic) NSDictionary *displayInfo;
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
@property(copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDisplayInfoValue:(id)value forKey:(id)key;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) unsigned int hiDPI;
@property(readonly, nonatomic) NSArray *modes;
@property(readonly, nonatomic) NSString *name;
@end

// ---------------------------------------------------------------------------
// The fixed identity table. THIS IS A GUARD, NOT A CONVENIENCE.
//
// macOS writes an .icc into /Library/ColorSync/Profiles/Displays/ for every
// display identity it has ever seen and never removes it — not on teardown,
// not on process death, not on reboot. A previous rig minted a fresh identity
// per run and per case and left 143 orphaned profiles, which took the ColorSync
// daemons to ~59% CPU.
//
// So every field below is a constant, reused by every run forever. The rig's
// entire permanent footprint is one profile per row of this table — six files,
// once, ever. Adding a row, or making any of these values vary at runtime,
// costs a permanent file per new value. Don't.
// ---------------------------------------------------------------------------

typedef struct {
  const char *label;
  const char *name;         // EDID display name; part of the ColorSync identity
  unsigned int vendorID;
  unsigned int productID;
  unsigned int serialNum;
  unsigned int width;       // fixed: geometry feeds the EDID, and a new EDID
  unsigned int height;      // may mint a new profile. Not runtime-settable.
  double widthMM;
  double heightMM;
} VDRigIdentity;

// Slots 1..3 — distinct identities, distinct sizes and aspect ratios so an
// arrangement canvas has visibly different tiles to place.
static const VDRigIdentity kVDRigSlots[3] = {
    {"slot1", "Candela Rig Slot 1", 0xCA1D, 0x1001, 0x00000001, 1920, 1080, 600, 340},
    {"slot2", "Candela Rig Slot 2", 0xCA1D, 0x1002, 0x00000002, 1680, 1050, 470, 300},
    {"slot3", "Candela Rig Slot 3", 0xCA1D, 0x1003, 0x00000003, 1280, 800, 340, 210},
};

// Twins — the single deliberate exception to "one identity per slot".
//
// vendorID / productID / serialNum are IDENTICAL. That triple is Candela's
// DisplayConfigIdentity, so these two collide exactly the way two units of the
// same monitor model do, which is the whole point of the mode.
//
// They differ ONLY in sizeInMillimeters, by 4mm × 2mm — and that difference is
// load-bearing, not decorative. MEASURED 2026-08-04:
//
//   * macOS refuses to create a second virtual display that is identical to a
//     standing one. `initWithDescriptor:` returns an object whose displayID
//     stays 0, in-process and cross-process alike; polling three seconds does
//     not help. Each holder alone succeeds; together, the second one fails.
//   * The identity macOS keys that refusal on ignores serialNum and ignores
//     name: twinA and twinB, with different names and different serials,
//     produced the SAME CGDisplayCreateUUIDFromDisplayID and reused the SAME
//     .icc, and still could not coexist.
//   * sizeInMillimeters does move that identity, so a millimetre of difference
//     buys two coexisting displays whose vendor/product/serial still collide.
//
// So this is the narrowest separation that gets two displays on screen at once
// while leaving DisplayConfigIdentity ambiguous, which is the condition the
// twin spike exists to test. If a future macOS refuses even this, the mode is
// dead and AR11's refuse-to-guess fallback is the answer by default.
//
// Names differ so the spike has ground truth about which display is which; the
// measurement above proves the name is not doing the separating.
static const VDRigIdentity kVDRigTwins[2] = {
    {"twinA", "Candela Rig Twin A", 0xCA1D, 0x1701, 0x00000017, 1920, 1080, 600, 340},
    {"twinB", "Candela Rig Twin B", 0xCA1D, 0x1701, 0x00000017, 1920, 1080, 604, 342},
};

#endif
