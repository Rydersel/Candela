#import <Foundation/Foundation.h>
#import <ColorSync/ColorSyncDevice.h>
static bool cb(CFDictionaryRef info, void *ctx) {
  NSDictionary *d = (__bridge NSDictionary *)info;
  printf("class=%s id=%s scope=%s\n  profileID=%s url=%s\n",
    [[d[(__bridge id)kColorSyncDeviceClass] description] UTF8String],
    [[d[(__bridge id)kColorSyncDeviceID] description] UTF8String],
    [[d[(__bridge id)kColorSyncDeviceUserScope] description] UTF8String] ?: "-",
    [[d[(__bridge id)kColorSyncDeviceProfileID] description] UTF8String] ?: "-",
    [[d[(__bridge id)kColorSyncDeviceProfileURL] description] UTF8String] ?: "-");
  return true;
}
int main(void) {
  ColorSyncIterateDeviceProfiles(cb, NULL);
  return 0;
}
