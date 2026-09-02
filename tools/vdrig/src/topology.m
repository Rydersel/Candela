// topology — dump the current display topology, sorted and diffable.
//
// READ-ONLY. It calls nothing that can change display state; build.sh proves
// that against this source and this binary.
//
// Enumeration is CGGetOnlineDisplayList, never CGGetActiveDisplayList: online
// means active OR mirrored OR sleeping, and with the panels asleep the active
// list reads zero, which makes a display sleep look like a departure.
//
// Output is one `display` line per display, sorted by displayID, plus a
// trailing `count` line. Every field is stable across runs that change nothing,
// so `diff` over two dumps is the teardown check.
//
// `--stable` omits the two fields that are not topology: active and asleep.
// Those move on their own — the built-in panel dozes off mid-run — and the
// rig's own teardown recovery (`caffeinate -u`) necessarily changes them. A
// restore check that diffs them reports a failure every time the panel naps.
//
// usage: topology [--ids-only] [--stable]

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Lives in ColorSync, not CoreGraphics, and is not in any public header on
// macOS 26. Declared here rather than dropped, because it is one of the two
// candidate disambiguators the twin-identity experiment has to test.
extern CFUUIDRef CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID display);

static int CompareIDs(const void *a, const void *b) {
  CGDirectDisplayID x = *(const CGDirectDisplayID *)a;
  CGDirectDisplayID y = *(const CGDirectDisplayID *)b;
  return (x > y) - (x < y);
}

static NSString *UUIDStringFor(CGDirectDisplayID did) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(did);
  if (!uuid) return @"none";
  CFStringRef s = CFUUIDCreateString(NULL, uuid);
  NSString *out = [NSString stringWithString:(__bridge NSString *)s];
  CFRelease(s);
  CFRelease(uuid);
  return out;
}

// Excluded from --stable: NSScreen omits mirror slaves entirely, so a name can
// vanish for reasons that are not a topology change.
static NSString *ScreenNameFor(CGDirectDisplayID did) {
  for (NSScreen *s in [NSScreen screens]) {
    if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == did) {
      return s.localizedName ?: @"?";
    }
  }
  return @"?";
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    int idsOnly = 0, stable = 0;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--ids-only")) {
        idsOnly = 1;
      } else if (!strcmp(argv[i], "--stable")) {
        stable = 1;
      } else {
        fprintf(stderr, "usage: topology [--ids-only] [--stable]\n");
        return 2;
      }
    }

    uint32_t count = 0;
    CGGetOnlineDisplayList(0, NULL, &count);
    CGDirectDisplayID ids[count > 0 ? count : 1];
    if (count > 0) CGGetOnlineDisplayList(count, ids, &count);
    qsort(ids, count, sizeof(CGDirectDisplayID), CompareIDs);

    CGDirectDisplayID main = CGMainDisplayID();

    if (idsOnly) {
      for (uint32_t i = 0; i < count; i++) printf("%u\n", ids[i]);
      return 0;
    }

    for (uint32_t i = 0; i < count; i++) {
      CGDirectDisplayID d = ids[i];
      CGRect b = CGDisplayBounds(d);
      CGDirectDisplayID mirrors = CGDisplayMirrorsDisplay(d);

      // CGDisplayIsBuiltin returns -1, not 0, for an unknown display ID —
      // measured 2026-08-04. Print it raw rather than coercing to a bool.
      printf("display %u origin=%.0f,%.0f size=%.0fx%.0f main=%d builtin=%d ",
             d, b.origin.x, b.origin.y, b.size.width, b.size.height,
             d == main ? 1 : 0, (int)CGDisplayIsBuiltin(d));
      if (!stable) {
        printf("active=%d asleep=%d ", CGDisplayIsActive(d) ? 1 : 0,
               CGDisplayIsAsleep(d) ? 1 : 0);
      }
      // vendor/model/serial ARE Candela's DisplayConfigIdentity. Printed so the
      // twin-identity experiment can see the collision it is reasoning about rather than
      // assume it from the descriptor it asked for.
      printf("vendor=0x%X model=0x%X serial=0x%X ", CGDisplayVendorNumber(d),
             CGDisplayModelNumber(d), CGDisplaySerialNumber(d));
      printf("mirrors=%u unit=%u uuid=%s", mirrors, CGDisplayUnitNumber(d),
             UUIDStringFor(d).UTF8String);
      if (!stable) printf(" name=\"%s\"", ScreenNameFor(d).UTF8String);
      printf("\n");
    }
    printf("count %u\n", count);
  }
  return 0;
}
