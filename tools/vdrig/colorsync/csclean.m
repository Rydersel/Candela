#import <Foundation/Foundation.h>
#import <ColorSync/ColorSyncDevice.h>
static NSMutableArray *dead;
static bool cb(CFDictionaryRef info, void *ctx) {
  NSDictionary *d = (__bridge NSDictionary *)info;
  id url = d[(__bridge id)kColorSyncDeviceProfileURL];
  if (!url || url == [NSNull null]) {
    id cls = d[(__bridge id)kColorSyncDeviceClass];
    id did = d[(__bridge id)kColorSyncDeviceID];
    if (cls && did) [dead addObject:@[cls, did]];
  }
  return true;
}
int main(void) {
  dead = [NSMutableArray new];
  ColorSyncIterateDeviceProfiles(cb, NULL);
  printf("dead entries: %lu\n", (unsigned long)dead.count);
  unsigned ok = 0, fail = 0;
  for (NSArray *e in dead) {
    if (ColorSyncUnregisterDevice((__bridge CFStringRef)e[0], (__bridge CFUUIDRef)e[1])) ok++;
    else fail++;
  }
  printf("unregistered: %u  failed: %u\n", ok, fail);
  return 0;
}
