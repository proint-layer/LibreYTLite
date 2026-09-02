#import "YTLDownloadManager.h"
#import <UIKit/UIKit.h>
#import <os/log.h>

// [YTLDL] os_log breadcrumbs (low volume: a handful of lines per download) for
//   log stream --predicate 'eventMessage CONTAINS "[YTLDL]"'
// Compiled out of release builds (same convention as YTLDBG) so the shipped dylib carries zero
// debug strings; a `YTL_POST_DEBUG` build re-enables them. Failures always surface to the user
// via an alert regardless, and that alert carries YouTube's own reason string.
#if defined(YTL_POST_DEBUG) || defined(YTL_ELM_RE)
static void ytlDL(NSString *s) { os_log(OS_LOG_DEFAULT, "[YTLDL] %{public}@", s); }
#define DLLOG(...) ytlDL([NSString stringWithFormat:__VA_ARGS__])
#else
#define DLLOG(...)
#endif

// --- InnerTube client context -------------------------------------------------------------
// ISOLATED so it's a one-spot swap when Google eventually retires the client. ANDROID_VR
// (Oculus/Quest) has been one of yt-dlp's most durable clients: it returns fully-formed URLs
// with no cipher and no PO-token requirement. If it ever gets locked we'd add a fallback here
// (and, worst case, JavaScriptCore + base.js for signature deciphering — not needed today).
// Endpoint is www.youtube.com (NOT googleapis.com) so the anonymous visitor cookies apply; no
// API key needed there. Client + UA mirror yt-dlp's android_vr (client name 28), the one client
// that returns ready non-SABR URLs. If Google retires it, this block + requestPlayer is the swap.
static NSString *const kITPlayerURL   = @"https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
static NSString *const kITClientName  = @"ANDROID_VR";
static NSString *const kITClientNum   = @"28";          // X-Youtube-Client-Name for ANDROID_VR
static NSString *const kITClientVer   = @"1.65.10";
static NSString *const kITUserAgent   = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
// Browser UA for the visitor-session priming GET (mints the anonymous cookies + visitorData).
static NSString *const kBrowserUA     = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15";

// First capture group of `pattern` in `s`, or nil.
static NSString *ytlFirstMatch(NSString *s, NSString *pattern) {
    if (!s.length) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSRange r = [m rangeAtIndex:1];
    return r.location == NSNotFound ? nil : [s substringWithRange:r];
}

// Registry of in-flight downloads. NSURLSession retains its delegate until invalidated, but the
// InnerTube-fetch phase runs before any session exists, so we pin `self` here for the whole job.
static NSMutableSet<YTLDownloadManager *> *gYTLActiveDownloads;

@interface YTLDownloadManager () <NSURLSessionDownloadDelegate>
@end

@implementation YTLDownloadManager {
    NSString *_videoID;
    NSString *_title;          // from videoDetails.title, for the filename
    NSString *_ext;            // "m4a" (AAC) or "opus" (webm), from the chosen format's mime
    NSURL *_mediaURL;
    NSString *_visitorData;    // anonymous visitor id scraped from the priming GET
    NSURLSession *_apiSession; // ephemeral (isolated cookie jar) for the visitor GET + /player POST
    NSURLSession *_session;    // download-delegate session for the media fetch
    UIAlertController *_hud;
    long long _lastPct;
    BOOL _finished;
    BOOL _cancelled;
}

+ (void)downloadAudioForVideoID:(NSString *)videoID {
    if (!videoID.length) return;
    YTLDownloadManager *m = [YTLDownloadManager new];
    m->_videoID = [videoID copy];
    @synchronized ([YTLDownloadManager class]) {
        if (!gYTLActiveDownloads) gYTLActiveDownloads = [NSMutableSet set];
        [gYTLActiveDownloads addObject:m];
    }
    DLLOG(@"start vid=%@", videoID);
    [m resolveThenDownload];
}

- (void)unregister {
    [_session finishTasksAndInvalidate];   // breaks the session→delegate retain, frees us
    _session = nil;
    [_apiSession finishTasksAndInvalidate]; // ephemeral cookie jar torn down
    _apiSession = nil;
    @synchronized ([YTLDownloadManager class]) { [gYTLActiveDownloads removeObject:self]; }
}

// --- top view controller (no dependency on YT internals) ----------------------------------
static UIViewController *ytlTopVC(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed)
        vc = vc.presentedViewController;
    return vc;
}

// --- progress HUD -------------------------------------------------------------------------
- (void)showHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_hud = [UIAlertController alertControllerWithTitle:@"Downloading audio"
                                                         message:@"Preparing…"
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [self->_hud addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                                     handler:^(UIAlertAction *a) {
            self->_cancelled = YES;       // stops a pending InnerTube completion from proceeding
            self->_hud = nil;
            [self->_session invalidateAndCancel];
            self->_session = nil;
            [self->_apiSession invalidateAndCancel];
            self->_apiSession = nil;
            [self unregister];
            DLLOG(@"cancelled vid=%@", self->_videoID);
        }]];
        [ytlTopVC() presentViewController:self->_hud animated:YES completion:nil];
    });
}

- (void)updateHUDMessage:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_hud.message = msg; });
}

// Dismiss the HUD, then run `then` from the now-top VC.
- (void)dismissHUDThen:(void (^)(void))then {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_hud) {
            [self->_hud dismissViewControllerAnimated:YES completion:then];
            self->_hud = nil;
        } else if (then) {
            then();
        }
    });
}

- (void)failWithMessage:(NSString *)msg {
    DLLOG(@"fail vid=%@ : %@", _videoID, msg);
    [self dismissHUDThen:^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Download failed"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [ytlTopVC() presentViewController:a animated:YES completion:nil];
    }];
    [self unregister];
}

// --- 1) resolve a real audio URL (anonymous visitor session → android_vr /player) ---------
- (void)resolveThenDownload {
    [self showHUD];
    // Ephemeral config = its OWN cookie jar, so the app's real login cookies never leak into
    // these requests — the whole exchange stays an anonymous throwaway visitor (no soft-ban
    // risk). Seed consent (SOCS=CAI) + pref cookies so the priming GET isn't bounced to a
    // consent interstitial.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    for (NSArray *kv in @[@[@"PREF", @"hl=en&tz=UTC"], @[@"SOCS", @"CAI"]]) {
        NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: kv[0], NSHTTPCookieValue: kv[1],
            NSHTTPCookieDomain: @".youtube.com", NSHTTPCookiePath: @"/"}];
        if (c) [cfg.HTTPCookieStorage setCookie:c];
    }
    _apiSession = [NSURLSession sessionWithConfiguration:cfg];
    [self primeVisitorSession];
}

// Step 1: a browser-UA GET of the watch page mints an anonymous visitor session — Set-Cookie
// visitor cookies (auto-stored + auto-replayed by _apiSession) plus a `visitorData` embedded in
// the HTML. Together these satisfy YouTube's "confirm you're not a bot" gate on the /player call
// below. Without them, android_vr /player 200s for popular videos but LOGIN_REQUIREs niche ones.
- (void)primeVisitorSession {
    [self updateHUDMessage:@"Preparing…"];
    NSString *watch = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&bpctr=9999999999&has_verified=1", _videoID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:watch]];
    [req setValue:kBrowserUA forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-us,en;q=0.5" forHTTPHeaderField:@"Accept-Language"];
    [[_apiSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (self->_cancelled) return;
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        self->_visitorData = ytlFirstMatch(html, @"\"visitorData\":\"([^\"]+)\"");
        DLLOG(@"visitor vid=%@ visitorData=%@", self->_videoID, self->_visitorData.length ? @"yes" : @"no");
        [self requestPlayer];   // proceed regardless: the visitor cookies alone often suffice
    }] resume];
}

// Step 2: android_vr /player, replaying the visitorData header + the visitor cookies (auto-
// attached by _apiSession). Returns classic ready URLs (no cipher/nsig/PO-token) for the account-
// free anonymous session.
- (void)requestPlayer {
    NSDictionary *ctx = @{ @"client": @{
        @"clientName": kITClientName, @"clientVersion": kITClientVer,
        @"deviceMake": @"Oculus", @"deviceModel": @"Quest 3", @"androidSdkVersion": @32,
        @"userAgent": kITUserAgent, @"osName": @"Android", @"osVersion": @"12L",
        @"hl": @"en", @"timeZone": @"UTC", @"utcOffsetMinutes": @0 } };
    NSDictionary *body = @{ @"context": ctx, @"videoId": _videoID,
                            @"contentCheckOk": @YES, @"racyCheckOk": @YES };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kITPlayerURL]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kITUserAgent forHTTPHeaderField:@"User-Agent"];
    [req setValue:kITClientNum forHTTPHeaderField:@"X-Youtube-Client-Name"];
    [req setValue:kITClientVer forHTTPHeaderField:@"X-Youtube-Client-Version"];
    [req setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    if (_visitorData.length) [req setValue:_visitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];

    [[_apiSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (self->_cancelled) return;
        if (err || !data) { [self failWithMessage:@"Couldn't reach YouTube. Check your connection and try again."]; return; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) { [self failWithMessage:@"Unexpected response from YouTube."]; return; }
        [self handlePlayerResponse:j];
    }] resume];
}

- (void)handlePlayerResponse:(NSDictionary *)j {
    NSDictionary *ps = [j[@"playabilityStatus"] isKindOfClass:NSDictionary.class] ? j[@"playabilityStatus"] : nil;
    NSString *status = ps[@"status"];
    if (status && ![status isEqualToString:@"OK"]) {
        NSString *reason = [ps[@"reason"] isKindOfClass:NSString.class] ? ps[@"reason"] : status;
        [self failWithMessage:[NSString stringWithFormat:@"YouTube won't serve this video (%@). Age-restricted or private videos aren't supported yet.", reason]];
        return;
    }

    NSDictionary *sd = [j[@"streamingData"] isKindOfClass:NSDictionary.class] ? j[@"streamingData"] : nil;
    NSArray *fmts = [sd[@"adaptiveFormats"] isKindOfClass:NSArray.class] ? sd[@"adaptiveFormats"] : nil;
    if (!fmts.count) { [self failWithMessage:@"No downloadable audio track was found for this video."]; return; }

    NSDictionary *best = [self bestAudioFormatFrom:fmts];
    NSString *url = [best[@"url"] isKindOfClass:NSString.class] ? best[@"url"] : nil;
    if (!url.length) { [self failWithMessage:@"No downloadable audio track was found for this video."]; return; }

    NSString *mime = [best[@"mimeType"] isKindOfClass:NSString.class] ? best[@"mimeType"] : @"";
    _ext = [mime hasPrefix:@"audio/mp4"] ? @"m4a" : @"opus";
    _mediaURL = [NSURL URLWithString:url];

    NSDictionary *vd = [j[@"videoDetails"] isKindOfClass:NSDictionary.class] ? j[@"videoDetails"] : nil;
    NSString *title = [vd[@"title"] isKindOfClass:NSString.class] ? vd[@"title"] : nil;
    _title = [self sanitizeFilename:title] ?: _videoID;

    DLLOG(@"resolved vid=%@ itag=%@ mime=%@ ext=%@", _videoID, best[@"itag"], [mime componentsSeparatedByString:@";"].firstObject, _ext);
    [self startDownload];
}

// Prefer AAC/m4a (itag 140 → 139) for universal playback + Files preview; fall back to the
// highest-bitrate audio otherwise (opus 251/250/249).
- (NSDictionary *)bestAudioFormatFrom:(NSArray *)fmts {
    NSDictionary *itag140 = nil, *itag139 = nil, *bestByBitrate = nil;
    long long bestBitrate = -1;
    for (NSDictionary *f in fmts) {
        if (![f isKindOfClass:NSDictionary.class]) continue;
        NSString *mime = [f[@"mimeType"] isKindOfClass:NSString.class] ? f[@"mimeType"] : @"";
        if (![mime hasPrefix:@"audio"]) continue;
        long long itag = [f[@"itag"] respondsToSelector:@selector(longLongValue)] ? [f[@"itag"] longLongValue] : 0;
        if (itag == 140) itag140 = f;
        else if (itag == 139) itag139 = f;
        long long br = [f[@"bitrate"] respondsToSelector:@selector(longLongValue)] ? [f[@"bitrate"] longLongValue] : 0;
        if (br > bestBitrate) { bestBitrate = br; bestByBitrate = f; }
    }
    return itag140 ?: (itag139 ?: bestByBitrate);
}

// --- 2) download the whole track to disk --------------------------------------------------
- (void)startDownload {
    if (_cancelled) return;
    [self updateHUDMessage:@"Starting…"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:_mediaURL];
    [req setValue:kITUserAgent forHTTPHeaderField:@"User-Agent"];
    [[_session downloadTaskWithRequest:req] resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
      totalBytesExpectedToWrite:(int64_t)expected {
    if (expected <= 0) { [self updateHUDMessage:[NSString stringWithFormat:@"%.1f MB…", total / 1e6]]; return; }
    long long pct = (long long)((total * 100) / expected);
    if (pct == _lastPct) return;
    _lastPct = pct;
    [self updateHUDMessage:[NSString stringWithFormat:@"%lld%%  (%.1f / %.1f MB)", pct, total / 1e6, expected / 1e6]];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didFinishDownloadingToURL:(NSURL *)location {
    // MUST move the file out of the temp location synchronously, before this method returns.
    NSString *name = [NSString stringWithFormat:@"%@.%@", _title.length ? _title : _videoID, _ext];
    NSURL *dest = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:dest error:nil];
    NSError *mvErr = nil;
    BOOL ok = [fm moveItemAtURL:location toURL:dest error:&mvErr];
    if (!ok) { DLLOG(@"move failed: %@", mvErr); [self failWithMessage:@"Couldn't save the downloaded file."]; return; }
    _finished = YES;
    DLLOG(@"done vid=%@ -> %@", _videoID, name);
    [self presentShareForFile:dest];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
      didCompleteWithError:(NSError *)error {
    if (error && !_finished && error.code != NSURLErrorCancelled) {
        [self failWithMessage:@"The download was interrupted. Please try again."];
    }
}

// --- 3) hand off to "Save to Files" -------------------------------------------------------
- (void)presentShareForFile:(NSURL *)fileURL {
    [self dismissHUDThen:^{
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
        UIViewController *top = ytlTopVC();
        // iPad: anchor the popover so it doesn't crash.
        av.popoverPresentationController.sourceView = top.view;
        av.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        av.popoverPresentationController.permittedArrowDirections = 0;
        av.completionWithItemsHandler = ^(UIActivityType type, BOOL done, NSArray *items, NSError *err) {
            [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];   // temp cleanup
            [self unregister];
        };
        [top presentViewController:av animated:YES completion:nil];
    }];
}

// --- filename sanitize --------------------------------------------------------------------
- (NSString *)sanitizeFilename:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length) return nil;
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:\n\r\t"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (clean.length > 80) clean = [clean substringToIndex:80];
    return clean.length ? clean : nil;
}

@end
