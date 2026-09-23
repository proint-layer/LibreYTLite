#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#define YT_BUNDLE_ID @"com.google.ios.youtube"
#define YT_NAME @"YouTube"

@interface SSOConfiguration : NSObject
@end

%group gSideloading
// Keychain patching
static NSString *accessGroupID() {
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           (__bridge NSString *)kSecClassGenericPassword, (__bridge NSString *)kSecClass,
                           @"bundleSeedID", kSecAttrAccount,
                           @"", kSecAttrService,
                           (id)kCFBooleanTrue, kSecReturnAttributes,
                           nil];
    CFDictionaryRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status == errSecItemNotFound)
        status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status != errSecSuccess)
        return nil;
    NSString *accessGroup = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];

    return accessGroup;
}

// IAmYouTube (https://github.com/PoomSmart/IAmYouTube/)
%hook YTVersionUtils
+ (NSString *)appName { return YT_NAME; }
+ (NSString *)appID { return YT_BUNDLE_ID; }
%end

%hook GCKBUtils
+ (NSString *)appIdentifier { return YT_BUNDLE_ID; }
%end

%hook GPCDeviceInfo
+ (NSString *)bundleId { return YT_BUNDLE_ID; }
%end

%hook OGLBundle
+ (NSString *)shortAppName { return YT_NAME; }
%end

%hook GVROverlayView
+ (NSString *)appName { return YT_NAME; }
%end

// (Removed dead OGLPhenotypeFlagServiceImpl bundleId hook -- that class is gone on 21.x, and the
// NSBundle bundle-id hooks below already spoof the identifier.)

%hook APMAEU
+ (BOOL)isFAS { return YES; }
%end

%hook GULAppEnvironmentUtil
+ (BOOL)isFromAppStore { return YES; }
%end

// Login source string — Google's SSO stack reports the calling app with this. Present on 21.25.5.
// (Restored from upstream IAmYouTube; this had drifted out of our copy.)
%hook SSOClientLogin
+ (NSString *)defaultSourceString { return YT_BUNDLE_ID; }
%end

// NOTE: upstream IAmYouTube also hooks
//   -[YTHotConfig clientInfraClientConfigIosEnableFillingEncodedHacksInnertubeContext] -> NO
// We deliberately DON'T: it is the only sideload hook that changes what the SERVER sends (it strips
// client "encoded hacks" from the InnerTube context), and the community-post image viewer parses
// those server-driven ELM payloads (id.ui.backstage.post / post_base_wrapper node ids). Suspected of
// Login does not need it -- SSOClientLogin + the NSBundle spoof do the work. (It was briefly
// suspected of breaking the community-post long-press; that turned out to be unrelated -- the
// long-press is gated on the `postManager` default, which a clean reinstall had reset. Omitted here
// purely to avoid changing server-sent payloads for no benefit.)

%hook SSOConfiguration
- (id)initWithClientID:(id)clientID supportedAccountServices:(id)supportedAccountServices {
    self = %orig;
    [self setValue:YT_NAME forKey:@"_shortAppName"];
    [self setValue:YT_BUNDLE_ID forKey:@"_applicationIdentifier"];
    return self;
}
%end

// Gate the bundle spoof on the RECEIVER being the main bundle, matching upstream IAmYouTube.
// (We previously used a caller-stack dladdr check, which only spoofed when the CALLER was inside the
// app bundle -- so a system framework asking on the app's behalf got the real id. Widened while
// chasing the Google sign-in block.)
#define isMainBundle() ([self isEqual:NSBundle.mainBundle])

%hook NSBundle
+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:YT_BUNDLE_ID]) return NSBundle.mainBundle;
    return %orig(identifier);
}

- (NSString *)bundleIdentifier {
    return isMainBundle() ? YT_BUNDLE_ID : %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dict = %orig;
    if (!isMainBundle())
        return %orig;
    NSMutableDictionary *info = [dict mutableCopy];
    if (info[@"CFBundleIdentifier"]) info[@"CFBundleIdentifier"] = YT_BUNDLE_ID;
    if (info[@"CFBundleDisplayName"]) info[@"CFBundleDisplayName"] = YT_NAME;
    if (info[@"CFBundleName"]) info[@"CFBundleName"] = YT_NAME;
    return info;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (!isMainBundle())
        return %orig;
    if ([key isEqualToString:@"CFBundleIdentifier"])
        return YT_BUNDLE_ID;
    if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"])
        return YT_NAME;
    return %orig;
}
%end

// Fix login for YouTube 18.13.2 and higher
%hook SSOKeychainHelper
+ (NSString *)accessGroup {
    return accessGroupID();
}
+ (NSString *)sharedAccessGroup {
    return accessGroupID();
}
%end

// (Removed dead SSOKeychainCore accessGroup/sharedAccessGroup -- those +methods are absent on
// SSOKeychainCore in 21.x; the SSOKeychainHelper block above provides them.)

// Fix App Group Directory by moving it to documents directory
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (groupIdentifier != nil) {
        NSArray *paths = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        NSURL *documentsURL = [paths lastObject];
        return [documentsURL URLByAppendingPathComponent:@"AppGroup"];
    }
    return %orig(groupIdentifier);
}
%end
%end

%ctor {
    BOOL isAppStoreApp = [[NSFileManager defaultManager] fileExistsAtPath:[[NSBundle mainBundle] appStoreReceiptURL].path];
    if (!isAppStoreApp) %init(gSideloading);
}
