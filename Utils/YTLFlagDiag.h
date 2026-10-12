// Flag-crash diagnostics + safety wrappers.
//
// Two crash families have repeatedly taken the app down, and BOTH are gated behind settings
// flags -- which is why they look like "some toggles crash the app":
//
//   A. A delayed -performSelector: whose selector doesn't exist at runtime. These are the
//      nastiest to diagnose because __NSFireDelayedPerform calls the selector from the run
//      loop ~1s later, so the code that SCHEDULED it is long gone from the stack -- the crash
//      report names only CoreFoundation/UIKit and never points at us.
//   B. -valueForKey:/-setValue:forKey: against a private ivar YouTube renamed or removed,
//      which throws NSUnknownKeyException (also SIGABRT, also not obviously ours).
//
// The wrappers below make both families SURVIVABLE: the guarded call is skipped instead of
// crashing, and (in a YTL_FLAG_DEBUG build) the miss is logged with the flag name and source
// site that caused it. That turns "the app died, bisect the toggles one by one" into a single
// run that enumerates every at-risk flag at once.
//
// Release builds keep the guards (a skipped feature beats a crash) and drop the logging.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Stringified __FILE__:__LINE__ of the call, so a report line points straight at the source.
#define YTL_STR2(x) #x
#define YTL_STR(x) YTL_STR2(x)
#define YTL_SITE (__FILE__ ":" YTL_STR(__LINE__))

// Schedule -performSelector:withObject:afterDelay: only if `target` actually responds.
// `flag` is the settings key that gated the call (for the report); `site` is __FILE__:__LINE__.
void ytlSafePerform(id _Nullable target, SEL sel, NSTimeInterval delay,
                    NSString *flag, const char *site);

// respondsToSelector: that REPORTS the first miss. For selectors we forward-declare ourselves
// (YTLite.h hand-rolls interfaces for private YouTube classes): the declaration satisfies the
// compiler on every build, so a property YouTube has since dropped reads as a clean `video.foo`
// and then aborts at runtime. Use this at any such access that a settings flag can reach.
BOOL ytlSafeResponds(id _Nullable obj, SEL sel, NSString *flag, const char *site);

// -valueForKey: that returns nil instead of throwing when the ivar/accessor is gone.
id _Nullable ytlSafeValueForKey(id _Nullable obj, NSString *key, NSString *flag, const char *site);

// -setValue:forKey: that no-ops instead of throwing. Returns YES if the write landed.
BOOL ytlSafeSetValue(id _Nullable obj, id _Nullable value, NSString *key,
                     NSString *flag, const char *site);

#if defined(YTL_FLAG_DEBUG)
// Records that `key` was read (first read per key is logged with its value).
void ytlTraceFlagRead(NSString *key, NSInteger value, BOOL isBool);
// Installs the uncaught-exception handler and writes the run header. Idempotent.
void ytlFlagDiagStart(void);
// Sweep override: when a sweep control file is present, force every bool off except one.
// Returns YES and fills *out when the override applies to `key`.
BOOL ytlSweepOverrideBool(NSString *key, BOOL *out);
BOOL ytlSweepOverrideInt(NSString *key, NSInteger *out);
#endif

NS_ASSUME_NONNULL_END
