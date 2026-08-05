// holder — owns 1..3 CGVirtualDisplays and parks.
//
// The rig is two processes because a single process can enumerate display modes
// for only the FIRST virtual display it creates; later ones report zero modes,
// and neither pumping the run loop nor the reconfiguration callback helps
// (measured 2026-08-03). So whatever inspects the displays must not be the
// process that owns them.
//
// This program creates displays and destroys them. It performs NO display
// reconfiguration of any kind — no origins, no modes, no mirroring, no prefs.
// build.sh enforces that mechanically against this source and this binary.
//
// Protocol on stdout, line-buffered:
//   READY <displayID> <w>x<h>   one per display, in creation order
//   READY-ALL <n>
//   BYE                          after a clean teardown
//   FAIL <reason>                on any failure to reach READY-ALL

#import "vdrig.h"

#import <AppKit/AppKit.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSMutableArray *gHeld;

static BOOL DisplayIsOnline(CGDirectDisplayID want) {
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

static void PumpRunLoop(double seconds) {
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static CGVirtualDisplay *CreateDisplay(const VDRigIdentity *identity) {
  Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
  Class vdCls = NSClassFromString(@"CGVirtualDisplay");
  Class setCls = NSClassFromString(@"CGVirtualDisplaySettings");
  Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
  if (!descCls || !vdCls || !setCls || !modeCls) return nil;

  CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
  desc.queue = dispatch_queue_create("candela.vdrig.holder", DISPATCH_QUEUE_SERIAL);
  desc.name = @(identity->name);
  desc.vendorID = identity->vendorID;
  desc.productID = identity->productID;
  desc.serialNum = identity->serialNum;
  desc.maxPixelsWide = identity->width;
  desc.maxPixelsHigh = identity->height;
  desc.sizeInMillimeters = CGSizeMake(identity->widthMM, identity->heightMM);
  desc.redPrimary = CGPointMake(0.640, 0.330);
  desc.greenPrimary = CGPointMake(0.300, 0.600);
  desc.bluePrimary = CGPointMake(0.150, 0.060);
  desc.whitePoint = CGPointMake(0.3127, 0.3290);

  CGVirtualDisplay *vd = [[vdCls alloc] initWithDescriptor:desc];
  if (!vd) return nil;

  CGVirtualDisplaySettings *settings = [[setCls alloc] init];
  settings.hiDPI = 0;
  settings.rotation = 0;
  settings.modes = @[ [[modeCls alloc] initWithWidth:identity->width
                                             height:identity->height
                                        refreshRate:60.0] ];
  [vd applySettings:settings];

  // Don't judge displayID == 0 on the first read. Poll it, so a slow assignment
  // is not misreported as a refusal — the difference matters, because a genuine
  // refusal is a fact about the API and a race is a fact about this program.
  double waited = 0;
  while (vd.displayID == 0 && waited < 3.0) {
    PumpRunLoop(0.25);
    waited += 0.25;
  }
  return vd.displayID == 0 ? nil : vd;
}

static void Teardown(const char *why) {
  fprintf(stdout, "TEARDOWN %s\n", why);
  fflush(stdout);
  [gHeld removeAllObjects];
  gHeld = nil;
  // Give WindowServer a beat to reclaim the displays before we exit, so that a
  // caller polling the topology sees the steady state rather than a race.
  PumpRunLoop(1.5);
  fprintf(stdout, "BYE\n");
  fflush(stdout);
  _exit(0);
}

static void InstallSignalHandling(void) {
  int sigs[] = {SIGTERM, SIGINT, SIGHUP};
  for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
    signal(sigs[i], SIG_IGN);
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[i], 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ Teardown("signal"); });
    dispatch_resume(src);
    // Intentionally leaked: it must live for the process's whole lifetime.
    CFBridgingRetain(src);
  }
}

static const VDRigIdentity *IdentityForLabel(const char *label) {
  for (int i = 0; i < 3; i++) {
    if (!strcmp(label, kVDRigSlots[i].label)) return &kVDRigSlots[i];
  }
  for (int i = 0; i < 2; i++) {
    if (!strcmp(label, kVDRigTwins[i].label)) return &kVDRigTwins[i];
  }
  return NULL;
}

static void Usage(void) {
  fprintf(stderr,
          "usage: holder [--count 1..3] [--identity LABEL] [--max-life SECS]\n"
          "  --count N        N displays from the fixed slot table (default 1)\n"
          "  --identity LABEL exactly one display with the named fixed identity;\n"
          "                   one of slot1 slot2 slot3 twinA twinB\n"
          "  --max-life SECS  self-terminate after SECS (default 900, 0 disables)\n"
          "\n"
          "Twins run as TWO holders, one per identity. A single process cannot\n"
          "create two virtual displays macOS considers identical, and neither can\n"
          "two processes — the second initWithDescriptor: yields displayID 0.\n"
          "rig.sh --twins does the two-holder dance for you.\n");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    int count = 1;
    const char *identityLabel = NULL;
    double maxLife = 900.0;

    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--count") && i + 1 < argc) {
        count = atoi(argv[++i]);
      } else if (!strcmp(argv[i], "--identity") && i + 1 < argc) {
        identityLabel = argv[++i];
      } else if (!strcmp(argv[i], "--max-life") && i + 1 < argc) {
        maxLife = atof(argv[++i]);
      } else {
        Usage();
        return 2;
      }
    }

    const VDRigIdentity *chosen[3];
    if (identityLabel) {
      const VDRigIdentity *one = IdentityForLabel(identityLabel);
      if (!one) {
        fprintf(stdout, "FAIL unknown identity '%s'\n", identityLabel);
        fflush(stdout);
        return 2;
      }
      count = 1;
      chosen[0] = one;
    } else {
      if (count < 1 || count > 3) {
        fprintf(stdout, "FAIL count must be 1..3 (the identity table has three slots)\n");
        fflush(stdout);
        return 2;
      }
      for (int i = 0; i < count; i++) chosen[i] = &kVDRigSlots[i];
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    InstallSignalHandling();

    gHeld = [NSMutableArray array];
    CGDirectDisplayID ids[3] = {0, 0, 0};

    // Burst: create every display back to back, then wait for them together —
    // a multi-display arrival, not a sequence of single ones.
    for (int i = 0; i < count; i++) {
      CGVirtualDisplay *vd = CreateDisplay(chosen[i]);
      if (!vd) {
        fprintf(stdout, "FAIL could not create display for %s\n", chosen[i]->label);
        fflush(stdout);
        Teardown("create-failed");
      }
      ids[i] = vd.displayID;
      [gHeld addObject:vd];
    }

    for (int i = 0; i < count; i++) {
      double waited = 0;
      while (!DisplayIsOnline(ids[i]) && waited < 10.0) {
        PumpRunLoop(0.25);
        waited += 0.25;
      }
      if (!DisplayIsOnline(ids[i])) {
        fprintf(stdout, "FAIL display %u never came online\n", ids[i]);
        fflush(stdout);
        Teardown("never-online");
      }
      CGRect b = CGDisplayBounds(ids[i]);
      fprintf(stdout, "READY %u %.0fx%.0f %s\n", ids[i], b.size.width, b.size.height,
              chosen[i]->label);
    }

    fprintf(stdout, "READY-ALL %d\n", count);
    fflush(stdout);

    if (maxLife > 0) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(maxLife * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{ Teardown("max-life"); });
    }

    CFRunLoopRun();
    Teardown("runloop-exit");
  }
  return 0;
}
