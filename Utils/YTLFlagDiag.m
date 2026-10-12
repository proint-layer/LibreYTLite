#import "YTLFlagDiag.h"
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <pthread.h>
#import <objc/runtime.h>

// Reporting machinery is DEBUG-ONLY. The guards in the wrappers below ship in release, but a
// release dylib must contain zero "[YTLITE]" strings (AGENTS.md 4), so none of this is compiled
// in -- YTL_DIAG_REPORT becomes a no-op and the report line is never even formatted.
#if defined(YTL_FLAG_DEBUG)

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
// Separate from gLock: hooks report from several threads (ASDisplayNode work is off-main), and
// without this two appends can interleave inside one line.
static pthread_mutex_t gWriteLock = PTHREAD_MUTEX_INITIALIZER;

// Every distinct (kind, key, site) we've already reported, so a wrapper called from
// -setFrame: (i.e. hundreds of times a second) still only produces one line.
static NSMutableSet<NSString *> *gSeen;
// How many times each reported event actually fired -- surfaced in the run summary so a
// one-off looks different from a hot-loop hazard.
static NSMutableDictionary<NSString *, NSNumber *> *gCounts;

static os_log_t ytlDiagLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.dvntm.ytlite", "flagdiag"); });
    return log;
}

static NSString *ytlDiagLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"YTLFlagDiag.log"];
    });
    return path;
}

// Append one line to the on-device report. We re-open per write rather than holding a handle:
// these are rare (deduped) events, and a closed file is a file that survives a hard crash.
static void ytlDiagAppend(NSString *line) {
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", @(CFAbsoluteTimeGetCurrent()), line];
    NSData *data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = ytlDiagLogPath();
    pthread_mutex_lock(&gWriteLock);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:data]; }
        @catch (__unused NSException *e) {}
        [fh closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
    pthread_mutex_unlock(&gWriteLock);
}

// Report `line` once per unique `token`; count every occurrence. Returns YES the first time.
static BOOL ytlDiagReportOnce(NSString *token, NSString *line) {
    BOOL first = NO;
    pthread_mutex_lock(&gLock);
    if (!gSeen) { gSeen = [NSMutableSet set]; gCounts = [NSMutableDictionary dictionary]; }
    if (![gSeen containsObject:token]) { [gSeen addObject:token]; first = YES; }
    gCounts[token] = @(gCounts[token].integerValue + 1);
    pthread_mutex_unlock(&gLock);

    if (first) {
        os_log(ytlDiagLog(), "[YTLITE] %{public}@", line);
        ytlDiagAppend(line);
    }
    return first;
}

#define YTL_DIAG_REPORT(tok, line) ytlDiagReportOnce((tok), (line))

#else
#define YTL_DIAG_REPORT(tok, line) ((void)0)
#endif

// ---------------------------------------------------------------------------
// Safety wrappers (guards are LIVE in release; only the reporting is debug-gated)
// ---------------------------------------------------------------------------

void ytlSafePerform(id target, SEL sel, NSTimeInterval delay, NSString *flag, const char *site) {
    if (target && [target respondsToSelector:sel]) {
        [target performSelector:sel withObject:nil afterDelay:delay];
        return;
    }
    // Without this guard the perform is queued anyway and the run loop fires it ~`delay`
    // later into doesNotRecognizeSelector: -- a SIGABRT whose backtrace never mentions us.
    (void)flag; (void)site;
    YTL_DIAG_REPORT(([NSString stringWithFormat:@"P|%@|%s", NSStringFromSelector(sel), site]),
                    ([NSString stringWithFormat:@"FLAGRISK perform flag=%@ sel=%@ cls=%@ site=%s",
                      flag, NSStringFromSelector(sel),
                      target ? NSStringFromClass([target class]) : @"(nil)", site]));
}

BOOL ytlSafeResponds(id obj, SEL sel, NSString *flag, const char *site) {
    if (obj && [obj respondsToSelector:sel]) return YES;
    (void)flag; (void)site;
    YTL_DIAG_REPORT(([NSString stringWithFormat:@"R|%@|%s", NSStringFromSelector(sel), site]),
                    ([NSString stringWithFormat:@"FLAGRISK selector flag=%@ sel=%@ cls=%@ site=%s",
                      flag, NSStringFromSelector(sel),
                      obj ? NSStringFromClass([obj class]) : @"(nil)", site]));
    return NO;
}

id ytlSafeValueForKey(id obj, NSString *key, NSString *flag, const char *site) {
    if (!obj) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        (void)flag; (void)site; (void)e;
        YTL_DIAG_REPORT(([NSString stringWithFormat:@"G|%@|%s", key, site]),
                        ([NSString stringWithFormat:@"FLAGRISK getKVC flag=%@ key=%@ cls=%@ ex=%@ site=%s",
                          flag, key, NSStringFromClass([obj class]), e.name, site]));
        return nil;
    }
}

BOOL ytlSafeSetValue(id obj, id value, NSString *key, NSString *flag, const char *site) {
    if (!obj) return NO;
    @try {
        [obj setValue:value forKey:key];
        return YES;
    } @catch (NSException *e) {
        (void)flag; (void)site; (void)e;
        YTL_DIAG_REPORT(([NSString stringWithFormat:@"S|%@|%s", key, site]),
                        ([NSString stringWithFormat:@"FLAGRISK setKVC flag=%@ key=%@ cls=%@ ex=%@ site=%s",
                          flag, key, NSStringFromClass([obj class]), e.name, site]));
        return NO;
    }
}

// ---------------------------------------------------------------------------
// Debug-only: flag-read trace, sweep driver, crash capture
// ---------------------------------------------------------------------------
#if defined(YTL_FLAG_DEBUG)

// Sweep control file. The harness drops this in Documents/ before each launch. We deliberately
// read a PLAIN FILE rather than NSUserDefaults: cfprefsd caches preference domains across
// launches, so a plist written from the host while the app is dead can be served stale. A file
// we open ourselves can't be.
//
//   all=on|off        baseline every BOOL flag reads
//   on=<k1,k2,...>    force these BOOLs YES (applied after the baseline)
//   off=<k1,k2,...>   force these BOOLs NO
//   only=<key>        sugar for `all=off` + `on=<key>` -- classic one-flag-at-a-time isolation
//   int:<key>=<n>     force an integer flag to <n>
//   label=<text>      free-text tag echoed into the run header
//
// Because the wrappers above make every known hazard survivable, the fast path is `all=on`:
// ONE launch reports every at-risk flag it reaches, instead of bisecting ~100 toggles.
static BOOL gSweepActive;
static BOOL gSweepHasBaseline;
static BOOL gSweepBaseline;
static NSString *gSweepLabel;
static NSMutableSet<NSString *> *gSweepOn;
static NSMutableSet<NSString *> *gSweepOff;
static NSMutableDictionary<NSString *, NSNumber *> *gSweepInts;

static void ytlSweepAddList(NSMutableSet *set, NSString *csv) {
    for (NSString *raw in [csv componentsSeparatedByString:@","]) {
        NSString *k = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (k.length) [set addObject:k];
    }
}

static void ytlSweepLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [docs stringByAppendingPathComponent:@"YTLSweep.txt"];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text.length) return;

        gSweepInts = [NSMutableDictionary dictionary];
        gSweepOn = [NSMutableSet set];
        gSweepOff = [NSMutableSet set];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!line.length || [line hasPrefix:@"#"]) continue;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *lhs = [line substringToIndex:eq.location];
            NSString *rhs = [line substringFromIndex:eq.location + 1];
            if ([lhs isEqualToString:@"all"]) {
                gSweepHasBaseline = YES; gSweepBaseline = [rhs isEqualToString:@"on"]; gSweepActive = YES;
            } else if ([lhs isEqualToString:@"only"]) {
                gSweepHasBaseline = YES; gSweepBaseline = NO; [gSweepOn addObject:rhs]; gSweepActive = YES;
            } else if ([lhs isEqualToString:@"on"])  { ytlSweepAddList(gSweepOn, rhs);  gSweepActive = YES; }
            else if ([lhs isEqualToString:@"off"])   { ytlSweepAddList(gSweepOff, rhs); gSweepActive = YES; }
            else if ([lhs isEqualToString:@"label"]) { gSweepLabel = rhs; }
            else if ([lhs hasPrefix:@"int:"])        { gSweepInts[[lhs substringFromIndex:4]] = @(rhs.integerValue); gSweepActive = YES; }
        }
    });
}

BOOL ytlSweepOverrideBool(NSString *key, BOOL *out) {
    ytlSweepLoad();
    if (!gSweepActive) return NO;
    // Explicit on=/off= beat the baseline; with no baseline and no mention, fall through to
    // the real stored value so a targeted sweep doesn't disturb unrelated settings.
    if ([gSweepOff containsObject:key]) { *out = NO;  return YES; }
    if ([gSweepOn  containsObject:key]) { *out = YES; return YES; }
    if (!gSweepHasBaseline) return NO;
    *out = gSweepBaseline;
    return YES;
}

BOOL ytlSweepOverrideInt(NSString *key, NSInteger *out) {
    ytlSweepLoad();
    if (!gSweepActive) return NO;
    NSNumber *forced = gSweepInts[key];
    if (!forced) return NO;
    *out = forced.integerValue;
    return YES;
}

void ytlDiagNote(NSString *msg) {
    // Not deduped: these are decision-point traces where the SEQUENCE and the repeat count are
    // the signal (e.g. "scan cached N groups" then "gallery resolved 1 image").
    os_log(ytlDiagLog(), "[YTLITE] %{public}@", msg);
    ytlDiagAppend(msg);
}

void ytlTraceFlagRead(NSString *key, NSInteger value, BOOL isBool) {
    // First read of each key only -- this fires from scroll-rate code paths.
    NSString *line = isBool
        ? [NSString stringWithFormat:@"FLAGREAD %@=%@", key, value ? @"YES" : @"NO"]
        : [NSString stringWithFormat:@"FLAGREAD %@=%ld", key, (long)value];
    ytlDiagReportOnce([@"R|" stringByAppendingString:key], line);
}

// Dump the per-token hit counts. Called from the crash handler and at app-background, so a run
// that survives still reports how hot each hazard was.
static void ytlDiagDumpCounts(NSString *reason) {
    pthread_mutex_lock(&gLock);
    NSArray *keys = [gCounts.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *s = [NSMutableString stringWithFormat:@"SUMMARY (%@) events=%lu", reason, (unsigned long)keys.count];
    for (NSString *k in keys) [s appendFormat:@" | %@ x%@", k, gCounts[k]];
    pthread_mutex_unlock(&gLock);
    os_log(ytlDiagLog(), "[YTLITE] %{public}@", s);
    ytlDiagAppend(s);
}

// iOS redacts the class and selector in an .ips crash report ("-[%s %s]: unrecognized selector"),
// which is exactly the information needed to find the culprit. Intercepting
// -doesNotRecognizeSelector: records both, plus the call stack, BEFORE the abort -- so every
// remaining phantom-selector crash names itself on the first occurrence instead of costing a
// guess-and-reinstall cycle. Debug builds only; it never suppresses the abort.
static void (*gOrigDNRS_NSObject)(id, SEL, SEL);
static void (*gOrigDNRS_UIResponder)(id, SEL, SEL);

static void ytlLogUnrecognized(id obj, SEL sel) {
    NSString *line = [NSString stringWithFormat:@"CRASH unrecognized -[%@ %@] stack: %@",
                      NSStringFromClass([obj class]), NSStringFromSelector(sel),
                      [[NSThread callStackSymbols] componentsJoinedByString:@" ;; "]];
    os_log_error(ytlDiagLog(), "[YTLITE] %{public}@", line);
    ytlDiagAppend(line);
}

static void ytlDNRS_NSObject(id self, SEL _cmd, SEL sel) {
    ytlLogUnrecognized(self, sel);
    if (gOrigDNRS_NSObject) gOrigDNRS_NSObject(self, _cmd, sel);
}
static void ytlDNRS_UIResponder(id self, SEL _cmd, SEL sel) {
    ytlLogUnrecognized(self, sel);
    if (gOrigDNRS_UIResponder) gOrigDNRS_UIResponder(self, _cmd, sel);
}

// UIResponder overrides doesNotRecognizeSelector:, so swizzling NSObject alone would miss every
// view and view controller -- i.e. most of what we touch. Hook both.
static void ytlInstallUnrecognizedLogger(void) {
    SEL sel = @selector(doesNotRecognizeSelector:);

    Method m = class_getInstanceMethod([NSObject class], sel);
    if (m) gOrigDNRS_NSObject = (void *)method_setImplementation(m, (IMP)ytlDNRS_NSObject);

    Class resp = NSClassFromString(@"UIResponder");
    Method rm = resp ? class_getInstanceMethod(resp, sel) : NULL;
    // Only swizzle if UIResponder really defines its own -- otherwise class_getInstanceMethod
    // hands back NSObject's and we would chain into ourselves.
    if (rm && method_getImplementation(rm) != (IMP)ytlDNRS_NSObject)
        gOrigDNRS_UIResponder = (void *)method_setImplementation(rm, (IMP)ytlDNRS_UIResponder);
}

static NSUncaughtExceptionHandler *gPrevHandler;

static void ytlUncaught(NSException *e) {
    // The whole point: an NSUnknownKeyException / unrecognized-selector abort records WHICH
    // flag-gated paths had run before it, which the .ips backtrace cannot tell us (a delayed
    // perform crashes with none of our frames on the stack).
    NSString *line = [NSString stringWithFormat:@"CRASH %@: %@ | stack: %@",
                      e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@" ;; "]];
    os_log_error(ytlDiagLog(), "[YTLITE] %{public}@", line);
    ytlDiagAppend(line);
    ytlDiagDumpCounts(@"crash");
    if (gPrevHandler) gPrevHandler(e);
}

void ytlFlagDiagStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ytlSweepLoad();
        gPrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&ytlUncaught);
        ytlInstallUnrecognizedLogger();

        NSString *header = [NSString stringWithFormat:@"RUNSTART sweep=%@ all=%@ on=%@ off=%@ ints=%@ label=%@",
                            gSweepActive ? @"YES" : @"NO",
                            gSweepHasBaseline ? (gSweepBaseline ? @"on" : @"off") : @"-",
                            [gSweepOn.allObjects componentsJoinedByString:@","] ?: @"-",
                            [gSweepOff.allObjects componentsJoinedByString:@","] ?: @"-",
                            gSweepInts ?: @{}, gSweepLabel ?: @"-"];
        os_log(ytlDiagLog(), "[YTLITE] %{public}@", header);
        ytlDiagAppend(header);

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                        object:nil queue:nil
                                                    usingBlock:^(__unused NSNotification *n) {
            ytlDiagDumpCounts(@"background");
        }];
    });
}

#endif // YTL_FLAG_DEBUG
