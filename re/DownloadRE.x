// DownloadRE.x — download-manager FEASIBILITY probe (RE harness, NOT shipped)
// ============================================================================
// Route 3 (Onesie capture): find where the app appends decoded media bytes per format so we can grab the
// audio (itag 140/139) and reassemble a .m4a. First guess -[MLOnesieVideoData appendMediaData:...] didn't
// fire. This build hooks EVERY Onesie append seam, unfiltered, and logs which one carries the bytes:
//   -[MLOnesieVideoData appendMediaData:offset:formatKey:]
//   -[MLOnesieDataBuffer appendData:formatKey:extraQOEDetails:]
//   -[MLOnesieDataBuffer appendData:offset:formatKey:extraQOEDetails:]
// If NONE fire during playback, the bytes are handled below ObjC in the C++ UMP parser (VideoPlaybackUmp
// ParserCallback) — a much harder seam — which is itself the key finding.
//
//   Build:  make clean package DEBUG=0 FINALPACKAGE=1 DL_RE=1
//   Read:   log stream --predicate 'eventMessage CONTAINS "[YTLDL]"'
// Not shipped: compiled ONLY when DL_RE=1. Log-and-%orig; never changes playback.

#if defined(YTL_DL_RE)

#import <Foundation/Foundation.h>
#import <os/log.h>

@interface MLOnesieFormatKey : NSObject
- (int)itag;
- (BOOL)isAudioFormat;
@end
@interface MLOnesieVideoData : NSObject
- (void)appendMediaData:(id)data offset:(long long)offset formatKey:(id)key;
@end
@interface MLOnesieDataBuffer : NSObject
- (void)appendData:(id)data formatKey:(id)key extraQOEDetails:(id)q;
- (void)appendData:(id)data offset:(long long)offset formatKey:(id)key extraQOEDetails:(id)q;
@end

static void dlLog(NSString *s) { os_log(OS_LOG_DEFAULT, "[YTLDL] %{public}@", s); }
#define DLOG(...) dlLog([NSString stringWithFormat:__VA_ARGS__])
static NSMutableDictionary *gYTLDLTotals;
static NSObject *gYTLDLLock;

static void dlTally(NSString *src, id data, id key) {
    @try {
        NSUInteger len = [data isKindOfClass:[NSData class]] ? [(NSData *)data length] : 0;
        int itag = [key respondsToSelector:@selector(itag)] ? [key itag] : -999;
        BOOL aud  = [key respondsToSelector:@selector(isAudioFormat)] ? [key isAudioFormat] : NO;
        @synchronized (gYTLDLLock ?: (gYTLDLLock = [NSObject new])) {
            if (!gYTLDLTotals) gYTLDLTotals = [NSMutableDictionary dictionary];
            NSString *k = [NSString stringWithFormat:@"%@:%d", src, itag];
            unsigned long long prev = [gYTLDLTotals[k] unsignedLongLongValue], tot = prev + len;
            gYTLDLTotals[k] = @(tot);
            if (prev == 0 || tot / (512 * 1024) != prev / (512 * 1024))   // first hit + every ~512KB
                DLOG(@"append[%@] itag=%d audio=%d +%luB total=%lluKB", src, itag, aud, (unsigned long)len, tot / 1024);
        }
    } @catch (__unused NSException *e) {}
}

%group gYTLDLProbe
%hook MLOnesieVideoData
- (void)appendMediaData:(id)data offset:(long long)offset formatKey:(id)key { %orig; dlTally(@"VD", data, key); }
%end
%hook MLOnesieDataBuffer
- (void)appendData:(id)data formatKey:(id)key extraQOEDetails:(id)q { %orig; dlTally(@"buf", data, key); }
- (void)appendData:(id)data offset:(long long)offset formatKey:(id)key extraQOEDetails:(id)q { %orig; dlTally(@"bufO", data, key); }
%end
%end // group

%ctor { %init(gYTLDLProbe); dlLog(@"download RE probe loaded (onesie capture, all seams)"); }

#endif // YTL_DL_RE
