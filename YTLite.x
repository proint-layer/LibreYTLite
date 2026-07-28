#import "YTLite.h"

#if defined(YTL_POST_DEBUG)
#import <os/log.h>
// NSLog redacts dynamic %@/%s as <private>; os_log with %{public}@ prints them.
static void ytlDbg(NSString *s) { os_log(OS_LOG_DEFAULT, "[YTLITE] %{public}@", s); }
#define YTLDBG(...) ytlDbg([NSString stringWithFormat:__VA_ARGS__])
#else
#define YTLDBG(...)
#endif

static UIImage *YTImageNamed(NSString *imageName) {
    return [UIImage imageNamed:imageName inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil];
}

// --- Multi-image community post cache ------------------------------------------------
// A post with a swipeable gallery is one EML element whose bytes list every image URL.
// Trouble is, the extra images render LAZILY -- at the moment you tap, only the first one
// exists in the view tree, so you can't find the rest by walking views. The dodge: the raw
// element bytes already hold all of them at FEED time. So we scan those bytes once as they
// go by (in the elementData hook), stash the ordered URL group, and when a post image is
// tapped we look the group up and page the whole set. Ugly, but it's the only place the
// full list is ever sitting in one piece.
static NSString *ytMaxResURLString(NSString *urlString);
static void ytlAddPhotoURLsFromString(NSString *s, NSMutableArray<NSURL *> *out);

static NSMutableArray<NSArray<NSString *> *> *gYTLImageGroups;   // each: ordered =s0 URLs
static NSObject *gYTLImageGroupsLock;

static void ytlRecordImageGroup(NSArray<NSURL *> *urls) {
    if (urls.count < 2) return;
    NSMutableArray<NSString *> *norm = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) [norm addObject:ytMaxResURLString(u.absoluteString)];
    @synchronized (gYTLImageGroupsLock ?: (gYTLImageGroupsLock = [NSObject new])) {
        if (!gYTLImageGroups) gYTLImageGroups = [NSMutableArray array];
        for (NSArray<NSString *> *g in gYTLImageGroups) {
            if ([g.firstObject isEqualToString:norm.firstObject]) return; // already cached
        }
        [gYTLImageGroups insertObject:norm atIndex:0];
        while (gYTLImageGroups.count > 60) [gYTLImageGroups removeLastObject];
    }
}

static NSArray<NSString *> *ytlImageGroupContaining(NSString *normURL) {
    if (!normURL) return nil;
    @synchronized (gYTLImageGroupsLock ?: (gYTLImageGroupsLock = [NSObject new])) {
        for (NSArray<NSString *> *g in gYTLImageGroups) {
            if ([g containsObject:normURL]) return g;
        }
    }
    return nil;
}

// Scans a feed elementRenderer's raw EML bytes for a multi-image post's image URLs and
// caches the group. Cheap-gated on the "fcrop64" crop marker so most renderers are skipped.
static void ytlScanAndCacheImages(NSData *data) {
    if (data.length == 0 || data.length > 600000) return;
    static NSData *marker; static dispatch_once_t once;
    dispatch_once(&once, ^{ marker = [@"fcrop64" dataUsingEncoding:NSASCIIStringEncoding]; });
    if ([data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]; // lossless byte->char
    if (!s) return;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    ytlAddPhotoURLsFromString(s, found);
    if (found.count >= 2) {
        ytlRecordImageGroup(found);
        YTLDBG(@"cached image group: %lu", (unsigned long)found.count);
    }
}

// ============================================================================
// ADS, BACKGROUND PLAYBACK & FEED FILTERING
//   background playback, ad/spam-signal suppression, EML ad-string filtering,
//   section/shelf ad removal, statement_banner view stripping
// ============================================================================

// YouTube-X (https://github.com/PoomSmart/YouTube-X/)
// Background Playback
%hook YTIPlayabilityStatus
- (BOOL)isPlayableInBackground { return ytlBool(@"backgroundPlayback") ? YES : NO; }
%end

%hook MLVideo
- (BOOL)playableInBackground { return ytlBool(@"backgroundPlayback") ? YES : NO; }
%end

// Kill ads. Video ads live on the player response, and they ride THREE
// separate arrays -- not one. We used to empty only playerAdsArray and the
// odd 6s bumper still snuck through as an "ad placement" or "ad slot" instead.
// So empty all three. An empty ad array is always valid; nothing downstream
// gets upset about it.
%hook YTIPlayerResponse
- (BOOL)isMonetized { return ytlBool(@"noAds") ? NO : YES; } // Tell the app the video isn't monetized.
- (NSMutableArray *)playerAdsArray    { return ytlBool(@"noAds") ? [NSMutableArray array] : %orig; }
- (NSMutableArray *)adPlacementsArray { return ytlBool(@"noAds") ? [NSMutableArray array] : %orig; } // DAI / bumpers hide here.
- (NSMutableArray *)adSlotsArray      { return ytlBool(@"noAds") ? [NSMutableArray array] : %orig; } // ...and here too.
%end

// Spam signals are the fingerprinting blob the app ships with ad requests.
// Hand back nil and it stops asking about ads with our device in tow.
%hook YTDataUtils
+ (id)spamSignalsDictionary { return ytlBool(@"noAds") ? nil : %orig; }
+ (id)spamSignalsDictionaryWithoutIDFA { return ytlBool(@"noAds") ? nil : %orig; }
%end

// These two stamp ad context onto every InnerTube request. Skip %orig and the
// request goes out clean -- no ad context, so the server has less to serve against.
%hook YTAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!ytlBool(@"noAds")) %orig; }
%end

%hook YTAccountScopedAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!ytlBool(@"noAds")) %orig; }
%end

%hook YTPlaybackConfig
- (void)setEnablePlayerAdUIRendering:(BOOL)enable { %orig(ytlBool(@"noAds") ? NO : enable); } // Don't even build the ad UI.
%end

// Belt and suspenders: if an ad break ever does start, swallow it. skipAd is
// the "skip" button's guts -- no-op it too so a stray break can't wedge.
%hook YTAdController
- (void)startAdBreak:(id)arg1 { if (!ytlBool(@"noAds")) %orig; }
- (void)skipAd { if (!ytlBool(@"noAds")) %orig; }
%end

// elementData is the raw bytes for one EML feed element. It's called on EVERY
// nested renderer, not just section roots -- keep that in mind below, it bites.
%hook YTIElementRenderer
- (NSData *)elementData {
    NSData *orig = %orig;

    // We're already looking at every element's bytes, so this is a free ride:
    // scan here to cache multi-image community-post URL groups (see cache up top).
    if (ytlBool(@"postManager")) ytlScanAndCacheImages(orig);

    // hasAdLoggingData is the app's own "this is an ad" tell. Trust it -- nil out
    // the whole element and the ad never renders.
    if (ytlBool(@"noAds") && self.hasCompatibilityOptions && self.compatibilityOptions.hasAdLoggingData)
        return nil;

    NSString *description = [self description];

    // WARNING: only match UNAMBIGUOUS ad names here. Generic layout names like
    // square_image_layout / carousel_headered_layout / text_image_button_layout
    // are ALSO used by community-post sub-renderers -- and since elementData
    // fires on every nested renderer, matching one of those nukes real posts too.
    NSArray *ads = @[@"brand_promo", @"text_search_ad", @"feed_ad_metadata",
                     @"statement_banner", @"ad_badge", @"promoted_sparkles_text_search_ad",
                     @"ads_video_bar"];
    for (NSString *ad in ads) {
        if (ytlBool(@"noAds") && [description containsString:ad])
            return [NSData data];
    }

    NSArray *shortsToRemove = @[@"shorts_shelf.eml", @"shorts_video_cell.eml", @"6Shorts"];
    for (NSString *shorts in shortsToRemove) {
        if (ytlBool(@"hideShorts") && [description containsString:shorts] && ![description containsString:@"history*"])
            return nil;
    }

    return orig;
}
%end

// Returns YES if an element renderer is an ad (EML-based, YouTube 19+)
static BOOL isAdElementRenderer(YTIElementRenderer *elementRenderer) {
    if (!elementRenderer) return NO;
    if ([elementRenderer respondsToSelector:@selector(hasCompatibilityOptions)] &&
        elementRenderer.hasCompatibilityOptions &&
        elementRenderer.compatibilityOptions.hasAdLoggingData)
        return YES;
    NSString *desc = [elementRenderer description];
    NSArray *adStrings = @[@"brand_promo", @"product_carousel", @"product_engagement_panel",
                           @"product_item", @"text_search_ad", @"feed_ad_metadata",
                           @"statement_banner", @"ad_badge", @"promoted_sparkles_text_search_ad",
                           @"shopping_companion", @"ads_video_bar"];
    for (NSString *adStr in adStrings) {
        if ([desc containsString:adStr]) return YES;
    }
    return NO;
}

// Filters ad sections and unwanted shelves from a section renderer array (makes a copy, safe for ASDK)
static NSMutableArray *ytlFilteredSections(NSArray *array) {
    if (!array) return nil;
    BOOL filterAds = ytlBool(@"noAds");
    BOOL filterContinueWatching = ytlBool(@"noContinueWatching");

    if (!filterAds && !filterContinueWatching)
        return [array mutableCopy];

    NSMutableArray *filtered = [array mutableCopy];
    NSIndexSet *removeIndexes = [filtered indexesOfObjectsPassingTest:^BOOL(id sectionRenderer, NSUInteger idx, BOOL *stop) {
        // Filter ads embedded inside shelf renderers
        if (filterAds && [sectionRenderer isKindOfClass:%c(YTIShelfRenderer)]) {
            YTIHorizontalListRenderer *hList = ((YTIShelfRenderer *)sectionRenderer).content.horizontalListRenderer;
            NSMutableArray *items = hList.itemsArray;
            NSIndexSet *adIndexes = [items indexesOfObjectsPassingTest:^BOOL(YTIHorizontalListSupportedRenderers *item, NSUInteger i, BOOL *s) {
                return isAdElementRenderer(item.elementRenderer);
            }];
            [items removeObjectsAtIndexes:adIndexes];
        }

        if (![sectionRenderer isKindOfClass:%c(YTIItemSectionRenderer)])
            return NO;

        YTIItemSectionRenderer *section = (YTIItemSectionRenderer *)sectionRenderer;
        NSMutableArray *contents = section.contentsArray;

        // Filter ad items within multi-item sections
        if (filterAds && contents.count > 1) {
            NSIndexSet *adIndexes = [contents indexesOfObjectsPassingTest:^BOOL(YTIItemSectionSupportedRenderers *item, NSUInteger i, BOOL *s) {
                return isAdElementRenderer(item.elementRenderer);
            }];
            [contents removeObjectsAtIndexes:adIndexes];
        }

        YTIItemSectionSupportedRenderers *firstItem = contents.firstObject;
        YTIElementRenderer *elementRenderer = firstItem.elementRenderer;

        // EML-based ad check (YouTube 19+)
        if (filterAds && isAdElementRenderer(elementRenderer))
            return YES;

        // Legacy typed-renderer ad check (older YouTube)
        if (filterAds && (firstItem.hasPromotedVideoRenderer ||
                          firstItem.hasCompactPromotedVideoRenderer ||
                          firstItem.hasPromotedVideoInlineMutedRenderer))
            return YES;

        // Horizontal card list shelf (Continue Watching, Explore different subjects, etc.)
        if (filterContinueWatching) {
            NSString *desc = [elementRenderer description];
            if ([desc containsString:@"horizontal_card_list"])
                return YES;
        }

        return NO;
    }];
    [filtered removeObjectsAtIndexes:removeIndexes];
    return filtered;
}

// Hook YTInnerTubeCollectionViewController (parent of YTSectionListViewController) to filter sections
// at the rendered-state level — safe for ASDK, operates on a copy not the raw proto model
%hook YTInnerTubeCollectionViewController
- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    NSMutableArray *sectionRenderers = [self valueForKey:@"_sectionRenderers"];
    NSMutableArray *filtered = ytlFilteredSections(sectionRenderers);
    if (filtered) [self setValue:filtered forKey:@"_sectionRenderers"];
    %orig;
}
- (void)addSectionsFromArray:(NSArray *)array {
    NSMutableArray *filtered = ytlFilteredSections(array);
    %orig(filtered ?: array);
}
%end

// Remove statement_banner promo views at the view layer (only when noAds is on)
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (!ytlBool(@"noAds")) return;
    NSString *identifier = self.accessibilityIdentifier;
    if ([identifier isEqualToString:@"statement_banner.view"])
        [self removeFromSuperview];
}
%end

// ============================================================================
// PREMIUM PROMO / INTERSTITIAL SUPPRESSION
// ============================================================================

// NOYTPremium (https://github.com/PoomSmart/NoYTPremium)
// Alert
%hook YTCommerceEventGroupHandler
- (void)addEventHandlers {}
%end

// Full-screen
%hook YTInterstitialPromoEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromosheetEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromoThrottleControllerImpl
- (BOOL)canShowThrottledPromo { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 { return NO; }
%end

%hook YTIShowFullscreenInterstitialCommand
- (BOOL)shouldThrottleInterstitial { return YES; }
%end

// "Try new features" in settings
%hook YTSettingsSectionItemManager
- (void)updatePremiumEarlyAccessSectionWithEntry:(id)arg1 {}
%end

// Survey
%hook YTSurveyController
- (void)showSurveyWithRenderer:(id)arg1 surveyParentResponder:(id)arg2 {}
%end

// ============================================================================
// NAVIGATION BAR & SEARCH
//   cast disable, nav-button hiding, voice search, search history
// ============================================================================

// Navbar Stuff
// Disable Cast
%hook MDXPlaybackRouteButtonController
- (BOOL)isPersistentCastIconEnabled { return ytlBool(@"noCast") ? NO : YES; }
- (void)updateRouteButton:(id)arg1 { if (!ytlBool(@"noCast")) %orig; }
- (void)updateAllRouteButtons { if (!ytlBool(@"noCast")) %orig; }
%end

%hook YTSettings
- (void)setDisableMDXDeviceDiscovery:(BOOL)arg1 { %orig(ytlBool(@"noCast")); }
%end

// Hide Navigation Bar Buttons
%hook YTRightNavigationButtons
- (void)layoutSubviews {
    %orig;

    if (ytlBool(@"noNotifsButton")) self.notificationButton.hidden = YES;
    if (ytlBool(@"noSearchButton")) self.searchButton.hidden = YES;

    for (UIView *subview in self.subviews) {
        if (ytlBool(@"noVoiceSearchButton") && [subview.accessibilityLabel isEqualToString:NSLocalizedString(@"search.voice.access", nil)]) subview.hidden = YES;
        if (ytlBool(@"noCast") && [subview.accessibilityIdentifier isEqualToString:@"id.mdx.playbackroute.button"]) subview.hidden = YES;
    }
}
%end

%hook YTSearchViewController
- (void)viewDidLoad {
    %orig;

    if (ytlBool(@"noVoiceSearchButton")) [self setValue:@(NO) forKey:@"_isVoiceSearchAllowed"];
}

- (void)setSuggestions:(id)arg1 { if (!ytlBool(@"noSearchHistory")) %orig; }
%end

%hook YTPersonalizedSuggestionsCacheProvider
- (id)activeCache { return ytlBool(@"noSearchHistory") ? nil : %orig; }
%end

// ============================================================================
// WATCH PAGE & PLAYER OVERLAY
//   related videos, sticky navbar, logo, subbar, overlay controls, HUD,
//   watermarks, miniplayer, progress bar
// ============================================================================

// Remove Videos Section Under Player
%hook YTWatchNextResultsViewController
- (void)setVisibleSections:(NSInteger)arg1 {
    arg1 = (ytlBool(@"noRelatedWatchNexts")) ? 1 : arg1;
    %orig(arg1);
}
%end

%hook YTHeaderView
// Stick Navigation bar
- (BOOL)stickyNavHeaderEnabled { return ytlBool(@"stickyNavbar") ? YES : %orig; }

// Hide YouTube Logo
- (void)setCustomTitleView:(UIView *)customTitleView { if (!ytlBool(@"noYTLogo")) %orig; }
- (void)setTitle:(NSString *)title { ytlBool(@"noYTLogo") ? %orig(@"") : %orig; }
%end

// Premium logo
%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (!ytlBool(@"premiumYTLogo")) return %orig;

    NSString *resourcesPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Frameworks/Module_Framework.framework/Innertube_Resources.bundle"];
    NSBundle *frameworkBundle = [NSBundle bundleWithPath:resourcesPath];

    if ([[image description] containsString:@"Resources: youtube_logo)"]) {
        image = [UIImage imageNamed:@"youtube_premium_logo" inBundle:frameworkBundle compatibleWithTraitCollection:nil];
    }

    else if ([[image description] containsString:@"Resources: youtube_logo_dark)"]) {
        image = [UIImage imageNamed:@"youtube_premium_logo_white" inBundle:frameworkBundle compatibleWithTraitCollection:nil];
    }

    %orig(image);
}
%end

// Remove Subbar
%hook YTMySubsFilterHeaderView
- (void)setChipFilterView:(id)arg1 { if (!ytlBool(@"noSubbar")) %orig; }
%end

%hook YTHeaderContentComboView
- (void)enableSubheaderBarWithView:(id)arg1 { if (!ytlBool(@"noSubbar")) %orig; }
- (void)setFeedHeaderScrollMode:(int)arg1 { ytlBool(@"noSubbar") ? %orig(0) : %orig; }
%end

%hook YTChipCloudCell
- (void)layoutSubviews {
    if (self.superview && ytlBool(@"noSubbar")) {
        [self removeFromSuperview];
    } %orig;
}
%end

%hook YTMainAppControlsOverlayView
// Hide Autoplay Switch
- (void)setAutoplaySwitchButtonRenderer:(id)arg1 { if (!ytlBool(@"hideAutoplay")) %orig; }

// Hide Subs Button
- (void)setClosedCaptionsOrSubtitlesButtonAvailable:(BOOL)arg1 { ytlBool(@"hideSubs") ? %orig(NO) : %orig; }

// Pause On Overlay
- (void)setOverlayVisible:(BOOL)visible {
    %orig;

    if (!ytlBool(@"pauseOnOverlay")) return;

    visible ? [self.playerViewController pause] : [self.playerViewController play];
}
%end

// Remove HUD Messages
%hook YTHUDMessageView
- (id)initWithMessage:(id)arg1 dismissHandler:(id)arg2 { return ytlBool(@"noHUDMsgs") ? nil : %orig; }
%end

%hook YTColdConfig
// ============================================================================
// PLAYER CONFIG FLAGS (YTColdConfig / YTHotConfig)
// ============================================================================

// Hide Next & Previous buttons
- (BOOL)removeNextPaddleForSingletonVideos { return ytlBool(@"hidePrevNext") ? YES : %orig; }
- (BOOL)removePreviousPaddleForSingletonVideos { return ytlBool(@"hidePrevNext") ? YES : %orig; }
// Replace Next & Previous with Fast Forward & Rewind buttons
- (BOOL)replaceNextPaddleWithFastForwardButtonForSingletonVods { return ytlBool(@"replacePrevNext") ? YES : %orig; }
- (BOOL)replacePreviousPaddleWithRewindButtonForSingletonVods { return ytlBool(@"replacePrevNext") ? YES : %orig; }
// Disable Free Zoom
- (BOOL)videoZoomFreeZoomEnabledGlobalConfig { return ytlBool(@"noFreeZoom") ? NO : %orig; }
// Stick Sort Buttons in Comments Section
- (BOOL)enableHideChipsInTheCommentsHeaderOnScrollIos { return ytlBool(@"stickSortComments") ? NO : %orig; }
// Hide Sort Buttons in Comments Section
- (BOOL)enableChipsInTheCommentsHeaderIos { return ytlBool(@"hideSortComments") ? NO : %orig; }
// Use System Theme
- (BOOL)shouldUseAppThemeSetting { return YES; }
// Dismiss Panel By Swiping in Fullscreen Mode
- (BOOL)isLandscapeEngagementPanelSwipeRightToDismissEnabled { return YES; }
// Remove Video in Playlist By Swiping To The Right
- (BOOL)enableSwipeToRemoveInPlaylistWatchEp { return YES; }
// Enable Old-style Minibar For Playlist Panel
- (BOOL)queueClientGlobalConfigEnableFloatingPlaylistMinibar { return ytlBool(@"playlistOldMinibar") ? NO : %orig; }
%end

// ============================================================================
// QUEUE — our own "watch queue" (Premium's is a lie, we built a real one)
// ============================================================================
// We chased YouTube's native mobile queue for a while. Dead end: it's gated on
// the SERVER. For a non-Premium account the "Add to queue" button ships with an
// upsell command baked in -- there's no client-side queue action to hook, no flag
// to flip. Verified the hard way (RE'd the binary, traced the commands on device).
// So forget theirs -- here's ours:
//   * long-press a feed video thumbnail -> "Add to queue"  (ytlQueueLongPress)
//   * the video ID falls right out of the thumbnail URL, i.ytimg.com/vi/<ID>/ --
//     no need to dig through the cell's guts (they're empty at press time anyway)
//   * when a video ends we just play the next one  (playbackControllerDidFinishPlayback:)
//     by opening vnd.youtube://<ID>, the same deep-link the app uses on itself.
// It's in-memory and deduped. So is theirs -- neither survives a relaunch.

// The list itself. @synchronized on everything because feed cells and the player
// poke it from different threads. Deduped: adding a video twice is a no-op.
@interface YTLQueueManager : NSObject
+ (instancetype)shared;
- (BOOL)enqueue:(NSString *)videoID;   // NO if already present
- (BOOL)contains:(NSString *)videoID;
- (void)remove:(NSString *)videoID;
- (NSString *)dequeue;                 // next video ID (removed), or nil if empty
- (NSUInteger)count;
- (void)clear;
- (NSArray<NSString *> *)allVideoIDs;  // ordered snapshot (for the viewer)
- (void)removeThroughIndex:(NSUInteger)idx;   // drop items 0…idx inclusive
- (void)moveFrom:(NSUInteger)from to:(NSUInteger)to;   // reorder (drag in the viewer)
@end

@implementation YTLQueueManager {
    NSMutableArray<NSString *> *_ids;
}
+ (instancetype)shared {
    static YTLQueueManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [YTLQueueManager new]; });
    return inst;
}
- (instancetype)init { if ((self = [super init])) _ids = [NSMutableArray array]; return self; }
- (BOOL)enqueue:(NSString *)videoID {
    if (!videoID.length) return NO;
    @synchronized (self) {
        if ([_ids containsObject:videoID]) return NO;
        [_ids addObject:videoID];
    }
    return YES;
}
- (BOOL)contains:(NSString *)videoID { @synchronized (self) { return videoID.length && [_ids containsObject:videoID]; } }
- (void)remove:(NSString *)videoID { @synchronized (self) { if (videoID) [_ids removeObject:videoID]; } }
- (NSString *)dequeue {
    @synchronized (self) {
        if (!_ids.count) return nil;
        NSString *next = _ids.firstObject;
        [_ids removeObjectAtIndex:0];
        return next;
    }
}
- (NSUInteger)count { @synchronized (self) { return _ids.count; } }
- (void)clear { @synchronized (self) { [_ids removeAllObjects]; } }
- (NSArray<NSString *> *)allVideoIDs { @synchronized (self) { return [_ids copy]; } }
- (void)removeThroughIndex:(NSUInteger)idx {
    @synchronized (self) {
        if (idx >= _ids.count) { [_ids removeAllObjects]; return; }
        [_ids removeObjectsInRange:NSMakeRange(0, idx + 1)];
    }
}
- (void)moveFrom:(NSUInteger)from to:(NSUInteger)to {
    @synchronized (self) {
        if (from >= _ids.count || to >= _ids.count || from == to) return;
        NSString *v = _ids[from];
        [_ids removeObjectAtIndex:from];
        [_ids insertObject:v atIndex:to];
    }
}
@end

// The responder-event that fires a navigation command (not in our imported headers).
@interface YTCommandResponderEvent : NSObject
+ (instancetype)eventWithCommand:(id)command entry:(id)entry sendClick:(BOOL)sendClick firstResponder:(id)firstResponder;
- (void)send;
@end

// The duration: variant of the toast (our header only has the no-duration one). Lets us
// make "Added to queue" flash by instead of lingering for the default ~4s.
@interface YTToastResponderEvent (YTLQueue)
+ (instancetype)eventWithMessage:(NSString *)message infoType:(NSInteger)infoType duration:(double)duration firstResponder:(id)firstResponder;
@end

// Queue session state. gYTLPlayer: the live player (weak, so it auto-nils). gYTLQueueEngaged:
// is the current playback session following our queue? (Only then do we auto-advance -- so
// exiting and later watching something unrelated won't get hijacked by a stale queue.)
// gYTLExpectingQueueLoad: set right before WE navigate to a queued video, so the upcoming
// load is recognized as queue-driven (vs. the user opening something else).
static __weak YTPlayerViewController *gYTLPlayer;
static BOOL gYTLQueueEngaged;
static BOOL gYTLExpectingQueueLoad;
static BOOL ytlVideoIsActive(void) { return gYTLPlayer != nil && gYTLPlayer.viewIfLoaded.window != nil; }

// Play a video by ID. This used to just open vnd.youtube://ID -- clean, but it DIED in
// the background: iOS won't let a backgrounded app open a URL, so with the screen off the
// queue just stopped. So now we fire YouTube's OWN watch-navigation command up the responder
// chain (exactly what a related-video tap sends). The watch controller catches it and
// reloads the current player IN PLACE -- no URL, no new screen -- which keeps working with
// the app backgrounded, same as its autoplay does. `responder` should be something live in
// the chain (hand it the player VC when you have one). openURL stays as a last-ditch fallback.
static void ytlPlayVideoID(NSString *videoID, id responder) {
    if (!videoID.length) return;
    gYTLExpectingQueueLoad = YES; // this navigation is queue-driven; keep the session engaged
    YTICommand *cmd = [%c(YTICommand) watchNavigationEndpointWithVideoID:videoID];
    if (!responder) responder = [%c(YTUIUtils) topViewControllerForPresenting];
    if (cmd && responder) {
        [[%c(YTCommandResponderEvent) eventWithCommand:cmd entry:nil sendClick:YES firstResponder:responder] send];
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"vnd.youtube://%@", videoID]];
    if (url && [[UIApplication sharedApplication] canOpenURL:url])
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

// The whole reason the queue works: a video thumbnail's URL literally spells out
// its ID -- i.ytimg.com/vi/<VIDEOID>/hq720.jpg. So we don't parse protobufs or walk
// the cell tree, we just yank the path segment between /vi/ (or /vi_webp/) and the
// next slash. IDs are always 11 chars of [A-Za-z0-9_-]; anything else isn't one.
static NSString *ytlVideoIDFromThumbnailURL(NSURL *url) {
    NSString *s = url.absoluteString;
    if (!s.length) return nil;
    for (NSString *marker in @[@"/vi/", @"/vi_webp/"]) {
        NSRange m = [s rangeOfString:marker];
        if (m.location == NSNotFound) continue;
        NSUInteger start = m.location + m.length;
        NSRange slash = [s rangeOfString:@"/" options:0 range:NSMakeRange(start, s.length - start)];
        if (slash.location == NSNotFound) continue;
        NSString *vid = [s substringWithRange:NSMakeRange(start, slash.location - start)];
        // YouTube video IDs are 11 chars of [A-Za-z0-9_-].
        if (vid.length == 11 &&
            [vid rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound)
            return vid;
    }
    return nil;
}

// Queue viewer -- our stand-in for the native "Up next" panel (which we can't populate;
// it's server-built, see the RE notes). Presented as a bottom sheet so it feels like YT's
// own panels. Tap a row to play it (dropping the ones before it), long-press-drag to
// reorder (instant + local -- no server round-trip, unlike a real playlist), swipe to
// remove, Clear to empty. Titles via YT's public oEmbed; thumbnails from i.ytimg.com.
@interface YTLQueueViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate>
@end

@implementation YTLQueueViewController {
    UITableView *_table;
    NSMutableArray<NSString *> *_items;
    NSMutableDictionary<NSString *, NSString *> *_titles;   // videoID → title
    NSMutableDictionary<NSString *, UIImage *> *_thumbs;    // videoID → thumbnail
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _items = [[[YTLQueueManager shared] allVideoIDs] mutableCopy];
    _titles = [NSMutableDictionary dictionary];
    _thumbs = [NSMutableDictionary dictionary];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self updateTitle];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(ytlDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOC(@"ClearQueue") style:UIBarButtonItemStylePlain target:self action:@selector(ytlClearAll)];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 76;
    // Long-press-drag reorder, native style. Keeps tap-to-play and swipe-remove working
    // (unlike edit-mode), which is how YT's own list panels behave.
    _table.dragInteractionEnabled = YES;
    _table.dragDelegate = self;
    _table.dropDelegate = self;
    [self.view addSubview:_table];

    for (NSString *vid in _items) [self fetchTitleFor:vid];
}

- (void)updateTitle { self.title = [NSString stringWithFormat:@"%@ (%lu)", LOC(@"UpNext"), (unsigned long)_items.count]; }
- (void)ytlDone { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)ytlClearAll {
    [[YTLQueueManager shared] clear];
    [_items removeAllObjects];
    [_table reloadData];
    [self updateTitle];
}

- (void)fetchTitleFor:(NSString *)videoID {
    if (_titles[videoID]) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.youtube.com/oembed?url=https://youtu.be/%@&format=json", videoID]];
    if (!url) return;
    __weak typeof(self) ws = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *title = [json isKindOfClass:[NSDictionary class]] ? json[@"title"] : nil;
        if (![title isKindOfClass:[NSString class]] || !title.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws; if (!ss) return;
            ss->_titles[videoID] = title;
            [ss->_table reloadData];
        });
    }];
    [task resume];
}

- (void)loadThumbFor:(NSString *)videoID atIndexPath:(NSIndexPath *)ip {
    __weak typeof(self) ws = self;
    NSURL *thumb = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *d = thumb ? [NSData dataWithContentsOfURL:thumb] : nil;
        UIImage *raw = d ? [UIImage imageWithData:d] : nil;
        if (!raw) return;
        // Downscale to a cell-sized thumbnail (the default cell imageView won't shrink a huge one).
        CGSize target = CGSizeMake(120, 68);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target];
        UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [raw drawInRect:CGRectMake(0, 0, target.width, target.height)]; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws; if (!ss) return;
            ss->_thumbs[videoID] = small;
            UITableViewCell *c = [ss->_table cellForRowAtIndexPath:ip];
            if (c) { c.imageView.image = small; [c setNeedsLayout]; }
        });
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"q"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"q"];
    NSString *vid = _items[ip.row];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.text = _titles[vid] ?: vid;
    cell.detailTextLabel.text = LOC(@"TapToPlay");
    UIImage *cached = _thumbs[vid];
    cell.imageView.image = cached;
    if (!cached) [self loadThumbFor:vid atIndexPath:ip];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *vid = _items[ip.row];
    [[YTLQueueManager shared] removeThroughIndex:ip.row]; // playing this one skips the ones before it
    [self dismissViewControllerAnimated:YES completion:^{ ytlPlayVideoID(vid, nil); }];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    [[YTLQueueManager shared] remove:_items[ip.row]];
    [_items removeObjectAtIndex:ip.row];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self updateTitle];
}

// --- drag-to-reorder (local only; a real playlist would POST an edit here) ---
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tv itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)ip {
    // Local reorder only -- the provider payload is unused, but drag needs an item.
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:_items[ip.row]]];
    item.localObject = _items[ip.row];
    return @[item];
}

- (BOOL)tableView:(UITableView *)tv canHandleDropSession:(id<UIDropSession>)session { return YES; }

- (UITableViewDropProposal *)tableView:(UITableView *)tv dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)dst {
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tv performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    NSIndexPath *dst = coordinator.destinationIndexPath ?: [NSIndexPath indexPathForRow:(_items.count ? _items.count - 1 : 0) inSection:0];
    for (id<UITableViewDropItem> dropItem in coordinator.items) {
        NSIndexPath *src = dropItem.sourceIndexPath;
        if (!src || src.row >= _items.count) continue;
        NSString *vid = _items[src.row];
        [_items removeObjectAtIndex:src.row];
        [_items insertObject:vid atIndex:dst.row];
        [[YTLQueueManager shared] moveFrom:src.row to:dst.row];
        [tv performBatchUpdates:^{
            [tv deleteRowsAtIndexPaths:@[src] withRowAnimation:UITableViewRowAnimationAutomatic];
            [tv insertRowsAtIndexPaths:@[dst] withRowAnimation:UITableViewRowAnimationAutomatic];
        } completion:nil];
        [coordinator dropItem:dropItem.dragItem toRowAtIndexPath:dst];
    }
}
@end

// Pop the queue viewer as a bottom sheet. Shared by the long-press "View queue" action and
// the player-overlay queue button.
static void ytlPresentQueueViewer(void) {
    YTLQueueViewController *vc = [YTLQueueViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sp = nav.sheetPresentationController;
        sp.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sp.prefersGrabberVisible = YES;
    }
    [[%c(YTUIUtils) topViewControllerForPresenting] presentViewController:nav animated:YES completion:nil];
}

// NOTE: no player-overlay queue button. We tried one (hand-rolled, then via YTVideoOverlay)
// and both broke iSponsorBlock's skip overlay -- iSponsorBlock does its OWN button management
// on YTMainAppControlsOverlayView (addSubview + a layoutSubviews hook), and a second manager on
// that view displaces its button. The queue is reachable via the long-press "View queue" action
// instead. If a watch-page button is revisited, it must not touch YTMainAppControlsOverlayView.

// Remove Dark Background in Overlay
%hook YTMainAppVideoPlayerOverlayView
- (void)setBackgroundVisible:(BOOL)arg1 isGradientBackground:(BOOL)arg2 { ytlBool(@"noDarkBg") ? %orig(NO, arg2) : %orig; }
%end

// No Endscreen Cards
%hook YTCreatorEndscreenView
- (void)setHidden:(BOOL)arg1 { ytlBool(@"endScreenCards") ? %orig(YES) : %orig; }
%end

// Disable Fullscreen Actions
%hook YTFullscreenActionsView
- (BOOL)enabled { return ytlBool(@"noFullscreenActions") ? NO : YES; }
- (void)setEnabled:(BOOL)arg1 { ytlBool(@"noFullscreenActions") ? %orig(NO) : %orig; }
%end

// Dont Show Related Videos on Finish
%hook YTFullscreenEngagementOverlayController
- (void)setRelatedVideosVisible:(BOOL)arg1 { ytlBool(@"noRelatedVids") ? %orig(NO) : %orig; }
%end

// Hide Paid Promotion Cards
%hook YTMainAppVideoPlayerOverlayViewController
- (void)setPaidContentWithPlayerData:(id)data { if (!ytlBool(@"noPromotionCards")) %orig; }
- (void)playerOverlayProvider:(YTPlayerOverlayProvider *)provider didInsertPlayerOverlay:(YTPlayerOverlay *)overlay {
    if ([[overlay overlayIdentifier] isEqualToString:@"player_overlay_paid_content"] && ytlBool(@"noPromotionCards")) return;
    %orig;
}
%end

%hook YTInlineMutedPlaybackPlayerOverlayViewController
- (void)setPaidContentWithPlayerData:(id)data { if (!ytlBool(@"noPromotionCards")) %orig; }
%end

%hook YTInlinePlayerBarContainerView
- (void)setPlayerBarAlpha:(CGFloat)alpha { ytlBool(@"persistentProgressBar") ? %orig(1.0) : %orig; }
%end

// Remove Watermarks
%hook YTAnnotationsViewController
- (void)loadFeaturedChannelWatermark { if (!ytlBool(@"noWatermarks")) %orig; }
%end

%hook YTMainAppVideoPlayerOverlayView
- (BOOL)isWatermarkEnabled { return ytlBool(@"noWatermarks") ? NO : %orig; }
%end

// Forcibly Enable Miniplayer
%hook YTWatchMiniBarViewController
- (void)updateMiniBarPlayerStateFromRenderer { if (!ytlBool(@"miniplayer")) %orig; }
%end

// Portrait Fullscreen
%hook YTWatchViewController
- (unsigned long long)allowedFullScreenOrientations { return ytlBool(@"portraitFullscreen") ? UIInterfaceOrientationMaskAllButUpsideDown : %orig; }
%end

// Disable Autoplay
%hook YTPlaybackConfig
- (void)setStartPlayback:(BOOL)arg1 { ytlBool(@"disableAutoplay") ? %orig(NO) : %orig; }
%end

// Skip Content Warning (https://github.com/qnblackcat/uYouPlus/blob/main/uYouPlus.xm#L452-L454)
%hook YTPlayabilityResolutionUserActionUIControllerImpl
- (void)showConfirmAlert { ytlBool(@"noContentWarning") ? [self confirmAlertDidPressConfirm] : %orig; }
%end

// Classic Video Quality (https://github.com/PoomSmart/YTClassicVideoQuality)
%hook YTVideoQualitySwitchControllerFactoryImpl
- (id)videoQualitySwitchControllerWithParentResponder:(id)responder {
    Class originalClass = %c(YTVideoQualitySwitchOriginalController);
    return ytlBool(@"classicQuality") && originalClass ? [[originalClass alloc] initWithParentResponder:responder] : %orig;
}
%end

// Extra Speed Options
%hook YTVarispeedSwitchControllerImpl
- (void)setDelegate:(id)arg1 {
    NSMutableArray *optionsCopy = [[self valueForKey:@"_options"] mutableCopy];
    NSArray *speedOptions = @[@"2.5", @"3", @"3.5", @"4", @"5"];

    for (NSString *title in speedOptions) {
        float rate = [title floatValue];
        YTVarispeedSwitchControllerOption *option = [[%c(YTVarispeedSwitchControllerOption) alloc] initWithTitle:title rate:rate];
        [optionsCopy addObject:option];
    }

    if (ytlBool(@"extraSpeedOptions")) [self setValue:[optionsCopy copy] forKey:@"_options"];

    return %orig;
}
%end

// Temprorary Fix For 'Classic Video Quality' and 'Extra Speed Options'
%hook YTVersionUtils
+ (NSString *)appVersion {
    NSString *originalVersion = %orig;
    NSString *fakeVersion = @"18.18.2";

    return (!ytlBool(@"classicQuality") && !ytlBool(@"extraSpeedOptions") && [originalVersion compare:fakeVersion options:NSNumericSearch] == NSOrderedDescending) ? originalVersion : fakeVersion;
}
%end

// Show real version in YT Settings
%hook YTSettingsCell
- (void)setDetailText:(id)arg1 {
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *appVersion = infoDictionary[@"CFBundleShortVersionString"];

    if ([arg1 isEqualToString:@"18.18.2"]) {
        arg1 = appVersion;
    } %orig(arg1);
}
%end

// Disable Snap To Chapter (https://github.com/qnblackcat/uYouPlus/blob/main/uYouPlus.xm#L457-464)
%hook YTSegmentableInlinePlayerBarView
- (void)didMoveToWindow { %orig; if (ytlBool(@"dontSnapToChapter")) self.enableSnapToChapter = NO; }
%end

// Red Progress Bar and Gray Buffer Progress
%hook YTInlinePlayerBarContainerView
- (id)quietProgressBarColor { return ytlBool(@"redProgressBar") ? [UIColor redColor] : %orig; }
%end

%hook YTSegmentableInlinePlayerBarView
- (void)setBufferedProgressBarColor:(id)arg1 { if (ytlBool(@"redProgressBar")) %orig([UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:0.60]); }
%end

// Disable Hints
%hook YTSettings
- (BOOL)areHintsDisabled { return ytlBool(@"noHints") ? YES : NO; }
- (void)setHintsDisabled:(BOOL)arg1 { ytlBool(@"noHints") ? %orig(YES) : %orig; }
%end

%hook YTUserDefaults
- (BOOL)areHintsDisabled { return ytlBool(@"noHints") ? YES : NO; }
- (void)setHintsDisabled:(BOOL)arg1 { ytlBool(@"noHints") ? %orig(YES) : %orig; }
%end

// ============================================================================
// PLAYBACK AUTOMATION
//   video end-time label, auto-skip shorts, auto quality/speed/fullscreen,
//   shorts->regular, caption handling, copy-timestamped-link
// ============================================================================

void addEndTime(YTPlayerViewController *self, YTSingleVideoController *video, YTSingleVideoTime *time) {
    if (!ytlBool(@"videoEndTime")) return;

    CGFloat rate = video.playbackRate != 0 ? video.playbackRate : 1.0;
    NSTimeInterval remainingTime = (lround(video.totalMediaTime) - lround(time.time)) / rate;

    NSDate *estimatedEndTime = [NSDate dateWithTimeIntervalSinceNow:remainingTime];

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [dateFormatter setDateFormat:ytlBool(@"24hrFormat") ? @"HH:mm" : @"h:mm a"];

    NSString *formattedEndTime = [dateFormatter stringFromDate:estimatedEndTime];

    YTPlayerView *playerView = (YTPlayerView *)self.view;
    if (![playerView.overlayView isKindOfClass:%c(YTMainAppVideoPlayerOverlayView)]) return;

    YTMainAppVideoPlayerOverlayView *overlay = (YTMainAppVideoPlayerOverlayView*)playerView.overlayView;
    YTLabel *durationLabel = overlay.playerBar.durationLabel;
    overlay.playerBar.endTimeString = formattedEndTime;

    if (![durationLabel.text containsString:formattedEndTime]) {
        durationLabel.text = [durationLabel.text stringByAppendingString:[NSString stringWithFormat:@" • %@", formattedEndTime]];
        [durationLabel sizeToFit];
    }
}

void autoSkipShorts(YTPlayerViewController *self, YTSingleVideoController *video, YTSingleVideoTime *time) {
    if (!ytlBool(@"autoSkipShorts")) return;

    if (floor(time.time) >= floor(video.totalMediaTime)) {
        if ([self.parentViewController isKindOfClass:%c(YTShortsPlayerViewController)]) {
            YTShortsPlayerViewController *shortsVC = (YTShortsPlayerViewController *)self.parentViewController;

            if ([shortsVC respondsToSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)]) {
                [shortsVC performSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)];
            }
        }
    }
}

%hook YTPlayerViewController
- (void)loadWithPlayerTransition:(id)arg1 playbackConfig:(id)arg2 {
    %orig;

    gYTLPlayer = self; // remember the live player so the queue knows if anything's playing
    // Engage the queue only for videos WE started; any other load (the user opened something
    // else, or came back later) disengages, so a stale queue can't hijack unrelated playback.
    if (gYTLExpectingQueueLoad) { gYTLExpectingQueueLoad = NO; gYTLQueueEngaged = YES; }
    else gYTLQueueEngaged = NO;

    if (ytlInt(@"wiFiQualityIndex") != 0 || ytlInt(@"cellQualityIndex") != 0) [self performSelector:@selector(autoQuality) withObject:nil afterDelay:1.0];
    if (ytlBool(@"autoFullscreen")) [self performSelector:@selector(autoFullscreen) withObject:nil afterDelay:0.75];
    if (ytlBool(@"shortsToRegular")) [self performSelector:@selector(shortsToRegular) withObject:nil afterDelay:0.75];
    if (ytlInt(@"autoSpeedIndex") != 3) [self performSelector:@selector(setAutoSpeed) withObject:nil afterDelay:0.75];
    if (ytlBool(@"disableAutoCaptions")) [self performSelector:@selector(turnOffCaptions) withObject:nil afterDelay:1.0];
}

// This is what makes the queue a QUEUE: the player tells us a video finished, and
// if we've got something lined up, we play it. Note it fires no matter what the
// autoplay toggle says -- a queue you built by hand should drain even with autoplay off.
- (void)playbackControllerDidFinishPlayback:(id)arg1 {
    %orig;
    // Only advance while the session is engaged with the queue (see gYTLQueueEngaged) -- so
    // exiting mid-queue and later finishing an unrelated video doesn't get hijacked.
    if (!ytlBool(@"enableQueue") || !gYTLQueueEngaged || ![YTLQueueManager shared].count) return;
    NSString *next = [[YTLQueueManager shared] dequeue];
    // Hand ytlPlayVideoID the player VC as the responder -- it's alive and in the chain
    // even when we're backgrounded, which is what lets the queue keep going with the screen off.
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ytlPlayVideoID(next, ws); });
}

%new
- (void)autoFullscreen {
    YTWatchController *watchController = [self valueForKey:@"_UIDelegate"];
    [watchController showFullScreen];
}

%new
- (void)shortsToRegular {
    if (self.contentVideoID != nil && [self.parentViewController isKindOfClass:NSClassFromString(@"YTShortsPlayerViewController")]) {
        NSString *vidLink = [NSString stringWithFormat:@"vnd.youtube://%@", self.contentVideoID];
        if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:vidLink]]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:vidLink] options:@{} completionHandler:nil];
        }
    }
}

%new
- (void)turnOffCaptions {
    if ([self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        [self setActiveCaptionTrack:nil];
    }
}

%new
- (void)setAutoSpeed {
    if ([self.activeVideoPlayerOverlay isKindOfClass:NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController")]
        && [self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        YTMainAppVideoPlayerOverlayViewController *overlayVC = (YTMainAppVideoPlayerOverlayViewController *)self.activeVideoPlayerOverlay;

        NSArray *speedLabels = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];
        [overlayVC setPlaybackRate:[speedLabels[ytlInt(@"autoSpeedIndex")] floatValue]];
    }
}

%new
- (void)autoQuality {
    if (![self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        return;
    }

    NetworkStatus status = [[Reachability reachabilityForInternetConnection] currentReachabilityStatus];
    NSInteger kQualityIndex = status == ReachableViaWiFi ? ytlInt(@"wiFiQualityIndex") : ytlInt(@"cellQualityIndex");

    NSString *bestQualityLabel;
    int highestResolution = 0;
    for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
        int reso = format.singleDimensionResolution;
        if (reso > highestResolution) {
            highestResolution = reso;
            bestQualityLabel = format.qualityLabel;
        }
    }

    NSArray *qualityLabels = @[@"Default", bestQualityLabel, @"2160p60", @"2160p", @"1440p60", @"1440p", @"1080p60", @"1080p", @"720p60", @"720p", @"480p", @"360p"];
    NSString *qualityLabel = qualityLabels[kQualityIndex];

    if (![qualityLabel isEqualToString:bestQualityLabel]) {
        BOOL exactMatch = NO;
        NSString *closestQualityLabel = qualityLabel;

        for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
            if ([format.qualityLabel isEqualToString:qualityLabel]) {
                exactMatch = YES;
                break;
            }
        }

        if (!exactMatch) {
            NSInteger bestQualityDifference = NSIntegerMax;

            for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
                NSArray *formatСomponents = [format.qualityLabel componentsSeparatedByString:@"p"];
                NSArray *targetComponents = [qualityLabel componentsSeparatedByString:@"p"];
                if (formatСomponents.count == 2) {
                    NSInteger formatQuality = [formatСomponents.firstObject integerValue];
                    NSInteger targetQuality = [targetComponents.firstObject integerValue];
                    NSInteger difference = labs(formatQuality - targetQuality);
                    if (difference < bestQualityDifference) {
                        bestQualityDifference = difference;
                        closestQualityLabel = format.qualityLabel;
                    }
                }
            }

            qualityLabel = closestQualityLabel;
        }
    }

    MLQuickMenuVideoQualitySettingFormatConstraint *fc = [[%c(MLQuickMenuVideoQualitySettingFormatConstraint) alloc] init];
    if ([fc respondsToSelector:@selector(initWithVideoQualitySetting:formatSelectionReason:qualityLabel:)]) {
        [self.activeVideo setVideoFormatConstraint:[fc initWithVideoQualitySetting:3 formatSelectionReason:2 qualityLabel:qualityLabel]];
    }
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;

    addEndTime(self, video, time);
    autoSkipShorts(self, video, time);
}

- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;

    addEndTime(self, video, time);
    autoSkipShorts(self, video, time);
}
%end

%hook YTInlinePlayerBarContainerView
%property (nonatomic, strong) NSString *endTimeString;
- (void)setPeekableViewVisible:(BOOL)visible {
    %orig;

    if (!ytlBool(@"videoEndTime")) return;

    if (self.endTimeString && ![self.durationLabel.text containsString:self.endTimeString]) {
        self.durationLabel.text = [self.durationLabel.text stringByAppendingString:[NSString stringWithFormat:@" • %@", self.endTimeString]];
        [self.durationLabel sizeToFit];
    }
}
%end

// Exit Fullscreen on Finish
%hook YTWatchFlowController
- (BOOL)shouldExitFullScreenOnFinish { return ytlBool(@"exitFullscreen") ? YES : NO; }
%end

%hook YTMainAppVideoPlayerOverlayViewController
// Disable Double Tap To Seek
- (BOOL)allowDoubleTapToSeekGestureRecognizer { return ytlBool(@"noDoubleTapToSeek") ? NO : %orig; }

// Disable Two Finger Double Tap
- (BOOL)allowTwoFingerDoubleTapGestureRecognizer { return ytlBool(@"noTwoFingerSnapToChapter") ? NO : %orig; }

// Copy Timestamped Link by Pressing On Pause
- (void)didPressPause:(id)arg1 {
    %orig;

    if (ytlBool(@"copyWithTimestamp")) {
        NSInteger mediaTimeInteger = (NSInteger)self.mediaTime;
        NSString *currentTimeLink = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&t=%lds", self.videoID, mediaTimeInteger];

        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = currentTimeLink;
    }
}
%end

// ============================================================================
// MISC UI FIXES & MENU / PLAYER-BUTTON REMOVAL
//   label fitting, playlist minibar, menu-action removal, under-player buttons
// ============================================================================

// Fit 'Play All' Buttons Text For Localizations
%hook YTQTMButton
- (UILabel *)titleLabel {
    UILabel *label = %orig;

    if ([self.accessibilityIdentifier isEqualToString:@"id.playlist.playall.button"]) {
        label.adjustsFontSizeToFitWidth = YES;
    }

    return label;
}
%end

// Fit Shorts Button Labels For Localizations
%hook YTReelPlayerButton
- (UILabel *)titleLabel {
    UILabel *label = %orig;
    label.adjustsFontSizeToFitWidth = YES;

    return label;
}
%end

// Fix Playlist Mini-bar Height For Small Screens
%hook YTPlaylistMiniBarView
- (void)setFrame:(CGRect)frame {
    if (frame.size.height < 54.0) frame.size.height = 54.0;
    %orig(frame);
}
%end

// Remove "Play next in queue" from the menu @PoomSmart (https://github.com/qnblackcat/uYouPlus/issues/1138#issuecomment-1606415080)
%hook YTMenuItemVisibilityHandler
- (BOOL)shouldShowServiceItemRenderer:(YTIMenuConditionalServiceItemRenderer *)renderer {
    if (ytlBool(@"removePlayNext") && renderer.icon.iconType == 251) {
        return NO;
    } return %orig;
}
%end

// Remove Download button from the menu
%hook YTDefaultSheetController
- (void)addAction:(YTActionSheetAction *)action {
    NSString *identifier = [action valueForKey:@"_accessibilityIdentifier"];

    NSDictionary *actionsToRemove = @{
        @"7": @(ytlBool(@"removeDownloadMenu")),
        @"1": @(ytlBool(@"removeWatchLaterMenu")),
        @"3": @(ytlBool(@"removeSaveToPlaylistMenu")),
        @"5": @(ytlBool(@"removeShareMenu")),
        @"12": @(ytlBool(@"removeNotInterestedMenu")),
        @"31": @(ytlBool(@"removeDontRecommendMenu")),
        @"58": @(ytlBool(@"removeReportMenu"))
    };

    if (![actionsToRemove[identifier] boolValue]) {
        %orig;
    }
}
%end

// Hide buttons under the video player (@PoomSmart)
static BOOL findCell(ASNodeController *nodeController, NSArray <NSString *> *identifiers) {
    for (id child in [nodeController children]) {
        if ([child isKindOfClass:%c(ELMNodeController)]) {
            NSArray <ELMComponent *> *elmChildren = [(ELMNodeController *)child children];
            for (ELMComponent *elmChild in elmChildren) {
                for (NSString *identifier in identifiers) {
                    if ([[elmChild description] containsString:identifier])
                        return YES;
                }
            }
        }

        if ([child isKindOfClass:%c(ASNodeController)]) {
            ASDisplayNode *childNode = ((ASNodeController *)child).node; // ELMContainerNode
            NSArray *yogaChildren = childNode.yogaChildren;
            for (ASDisplayNode *displayNode in yogaChildren) {
                if ([identifiers containsObject:displayNode.accessibilityIdentifier])
                    return YES;
            }

            return findCell(child, identifiers);
        }

        return NO;
    }
    return NO;
}

%hook ASCollectionView
- (CGSize)sizeForElement:(ASCollectionElement *)element {
    if ([self.accessibilityIdentifier isEqualToString:@"id.video.scrollable_action_bar"]) {
        ASCellNode *node = [element node];
        ASNodeController *nodeController = [node controller];

        if (ytlBool(@"noPlayerRemixButton") && findCell(nodeController, @[@"id.video.remix.button"])) {
            return CGSizeZero;
        }

        if (ytlBool(@"noPlayerClipButton") && findCell(nodeController, @[@"clip_button.eml"])) {
            return CGSizeZero;
        }

        if (ytlBool(@"noPlayerDownloadButton") && findCell(nodeController, @[@"id.ui.add_to.offline.button"])) {
            return CGSizeZero;
        }
    }

    return %orig;
}
%end


// ============================================================================
// SHORTS
//   progress bar, startup suppression, element hiding, pinch-to-fullscreen,
//   shorts-only mode
// ============================================================================

// Shorts Progress Bar (https://github.com/PoomSmart/YTShortsProgress)
%hook YTReelPlayerViewController
- (BOOL)shouldEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTReelPlayerViewControllerSub
- (BOOL)shouldEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTShortsPlayerViewController
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTColdConfig
- (BOOL)iosEnableVideoPlayerScrubber { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)mobileShortsTabInlined { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)iosUseSystemVolumeControlInFullscreen { return ytlBool(@"stockVolumeHUD") ? YES : NO; }
%end

%hook YTHotConfig
- (BOOL)enablePlayerBarForVerticalVideoWhenControlsHiddenInFullscreen { return ytlBool(@"shortsProgress") ? YES : NO; }
%end

// Dont Startup Shorts
%hook YTShortsStartupCoordinatorImpl
- (id)evaluateResumeToShorts { return ytlBool(@"resumeShorts") ? nil : %orig; }
%end

// Hide Shorts Elements
%hook YTReelPausedStateCarouselView
- (void)setPausedStateCarouselVisible:(BOOL)arg1 animated:(BOOL)arg2 { ytlBool(@"hideShortsSubscriptions") ? %orig(arg1 = NO, arg2) : %orig; }
%end

%hook YTReelWatchPlaybackOverlayView
- (void)setReelLikeButton:(id)arg1 { if (!ytlBool(@"hideShortsLike")) %orig; }
- (void)setReelDislikeButton:(id)arg1 { if (!ytlBool(@"hideShortsDislike")) %orig; }
- (void)setViewCommentButton:(id)arg1 { if (!ytlBool(@"hideShortsComments")) %orig; }
- (void)setRemixButton:(id)arg1 { if (!ytlBool(@"hideShortsRemix")) %orig; }
- (void)setShareButton:(id)arg1 { if (!ytlBool(@"hideShortsShare")) %orig; }
- (void)setNativePivotButton:(id)arg1 { if (!ytlBool(@"hideShortsAvatars")) %orig; }
- (void)setPivotButtonElementRenderer:(id)arg1 { if (!ytlBool(@"hideShortsAvatars")) %orig; }
%end

%hook YTReelHeaderView
- (void)setTitleLabelVisible:(BOOL)arg1 animated:(BOOL)arg2 { ytlBool(@"hideShortsLogo") ? %orig(arg1 = NO, arg2) : %orig; }
%end

%hook YTReelTransparentStackView
- (void)layoutSubviews {
    %orig;

    for (YTQTMButton *button in self.subviews) {
        if ([button respondsToSelector:@selector(buttonRenderer)]) {
            if (ytlBool(@"hideShortsSearch") && button.buttonRenderer.icon.iconType == 1045) button.hidden = YES;
            if (ytlBool(@"hideShortsCamera") && button.buttonRenderer.icon.iconType == 1046) button.hidden = YES;
            if (ytlBool(@"hideShortsMore") && button.buttonRenderer.icon.iconType == 1047) button.hidden = YES;
        }
    }
}
%end

%hook YTReelWatchHeaderView
- (void)setChannelBarElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsChannelName")) %orig; }
- (void)setHeaderRenderer:(id)renderer { if (!ytlBool(@"hideShortsDescription")) %orig; }
- (void)setShortsVideoTitleElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsDescription")) %orig; }
- (void)setSoundMetadataElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsAudioTrack")) %orig; }
- (void)setActionElement:(id)renderer { if (!ytlBool(@"hideShortsPromoCards")) %orig; }
- (void)setBadgeRenderer:(id)renderer { if (!ytlBool(@"hideShortsThanks")) %orig; }
- (void)setMultiFormatLinkElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsSource")) %orig; }
%end

static BOOL isOverlayShown = YES;

%hook YTPlayerView
- (void)didPinch:(UIPinchGestureRecognizer *)gesture {
    %orig;

    if (ytlBool(@"pinchToFullscreenShorts") && [self.playerViewDelegate.parentViewController isKindOfClass:NSClassFromString(@"YTShortsPlayerViewController")]) {
        YTShortsPlayerViewController *shortsPlayerVC = (YTShortsPlayerViewController *)self.playerViewDelegate.parentViewController;
        YTReelContentView *contentView = (YTReelContentView *)shortsPlayerVC.view;
        UIWindow *mainWindow = [[[UIApplication sharedApplication] delegate] window];
        YTAppViewControllerImpl *appVC = (YTAppViewControllerImpl *)mainWindow.rootViewController;

        if (gesture.scale > 1) {
            if (!ytlBool(@"shortsOnlyMode")) [appVC hidePivotBar];

            [UIView animateWithDuration:0.3 animations:^{
                contentView.playbackOverlay.alpha = 0;
                isOverlayShown = contentView.playbackOverlay.alpha;
            }];
        } else {
            if (!ytlBool(@"shortsOnlyMode")) [appVC showPivotBar];

            [UIView animateWithDuration:0.3 animations:^{
                contentView.playbackOverlay.alpha = 1;
                isOverlayShown = contentView.playbackOverlay.alpha;
            }];
        }
    }
}
%end

%hook YTReelContentView
- (void)setPlaybackView:(id)arg1 {
    %orig;

    self.playbackOverlay.alpha = isOverlayShown;

    if (ytlBool(@"shortsOnlyMode")) {
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(turnShortsOnlyModeOff:)];
        longPressGesture.numberOfTouchesRequired = 2;
        longPressGesture.minimumPressDuration = 0.5;

        [self addGestureRecognizer:longPressGesture];
    }
}

%new
- (void)turnShortsOnlyModeOff:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ytlSetBool(NO, @"shortsOnlyMode");

        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"ShortsModeTurnedOff") firstResponder:[%c(YTUIUtils) topViewControllerForPresenting]] send];

        UIWindow *mainWindow = [[[UIApplication sharedApplication] delegate] window];
        YTAppViewControllerImpl *appVC = (YTAppViewControllerImpl *)mainWindow.rootViewController;
        [appVC performSelector:@selector(showPivotBar) withObject:nil afterDelay:1.0];
    }
}
%end

// ============================================================================
// COMMUNITY POST: IMAGE URL HELPERS, FULLSCREEN GALLERY & GESTURES
//   (the multi-image group cache is near the top of this file)
//   URL sizing, node-tree image lookup, Photos auth/save, YTLZoomView,
//   YTLImageViewer, long-press action menus, tap-to-open gallery
// ============================================================================

// Rewrites a Google image CDN URL (ggpht / googleusercontent) to a given size option.
// The options string follows the first '=' (e.g. "=s800-c-fcrop64=1,…-rw-nd-v1");
// replacing it drops the crop/downscale. sizeOption is e.g. "=s0" (original) or
// "=s2048". Non-Google URLs are returned unchanged.
static NSString *ytSizedURLString(NSString *urlString, NSString *sizeOption) {
    if (!urlString) return urlString;
    if (![urlString containsString:@"ggpht.com"] && ![urlString containsString:@"googleusercontent.com"])
        return urlString;
    NSRange eqRange = [urlString rangeOfString:@"="];
    NSString *base = (eqRange.location == NSNotFound) ? urlString : [urlString substringToIndex:eqRange.location];
    return [base stringByAppendingString:sizeOption];
}

// "=s0" is the original full resolution — better than merely stripping the size token.
static NSString *ytMaxResURLString(NSString *urlString) {
    return ytSizedURLString(urlString, @"=s0");
}

// Returns a node's image URL if it exposes one (ASNetworkImageNode and subclasses,
// or any node responding to -URL). Filtering out avatar-sized thumbnails is left to callers.
static NSURL *nodeImageURL(ASDisplayNode *node) {
    if ([node respondsToSelector:@selector(URL)]) {
        id u = [(id)node URL];
        if ([u isKindOfClass:[NSURL class]]) return (NSURL *)u;
    }
    return nil;
}

// Walks a node tree depth-first (both yogaChildren and subnodes) for the first image URL.
static NSURL *findImageURLInNode(ASDisplayNode *node, int depth) {
    if (!node || depth > 12) return nil;
    NSURL *own = nodeImageURL(node);
    if (own) return own;
    for (ASDisplayNode *child in node.yogaChildren) {
        NSURL *url = findImageURLInNode(child, depth + 1);
        if (url) return url;
    }
    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subs = [node valueForKey:@"subnodes"];
        for (ASDisplayNode *child in subs) {
            NSURL *url = findImageURLInNode(child, depth + 1);
            if (url) return url;
        }
    }
    return nil;
}

// Getting permission to save a photo, the annoying way. YouTube's Info.plist has the
// read-write Photos key but NOT the add-only one -- so the easy calls are off the table.
// WARNING: do NOT use UIImageWriteToSavedPhotosAlbum here; with no add-only description
// key it just fails silently. We ask for the READ-WRITE level instead and save through
// PHPhotoLibrary. done(YES) always comes back on the main queue.
static void ytlEnsurePhotosAuth(void (^done)(BOOL granted)) {
    if (@available(iOS 14.0, *)) {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(YES); });
        } else {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus s) {
                BOOL ok = (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited);
                dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
            }];
        }
    } else {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
        if (status == PHAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(YES); });
        } else {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus s) {
                BOOL ok = (s == PHAuthorizationStatusAuthorized);
                dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
            }];
        }
    }
}

static void downloadImageFromURL(UIResponder *responder, NSURL *URL, BOOL download) {
    NSString *URLString = URL.absoluteString;

    if (ytlBool(@"fixAlbums") && [URLString hasPrefix:@"https://yt3."]) {
        URLString = [URLString stringByReplacingOccurrencesOfString:@"https://yt3." withString:@"https://yt4."];
    }

    // =s0 requests the original full-res, uncropped image (better than the old
    // c-fcrop -> nd-v1 rewrite, which kept the =s800 downscale).
    NSURL *downloadURL = [NSURL URLWithString:ytMaxResURLString(URLString)] ?: URL;

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithURL:downloadURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            if (download) {
                ytlEnsurePhotosAuth(^(BOOL granted) {
                    if (!granted) {
                        [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), @"Photos access denied"] firstResponder:responder] send];
                        return;
                    }
                    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                        [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
                    } completionHandler:^(BOOL success, NSError *error) {
                        [[%c(YTToastResponderEvent) eventWithMessage:success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription] firstResponder:responder] send];
                    }];
                });
            } else {
                [UIPasteboard generalPasteboard].image = [UIImage imageWithData:data];
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:responder] send];
            }
        } else {
            [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription] firstResponder:responder] send];
        }
    }] resume];
}

static void genImageFromLayer(CALayer *layer, UIColor *backgroundColor, void (^completionHandler)(UIImage *)) {
    UIGraphicsBeginImageContextWithOptions(layer.frame.size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, backgroundColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, layer.frame.size.width, layer.frame.size.height));
    [layer renderInContext:context];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (completionHandler) {
        completionHandler(image);
    }
}

%hook ELMContainerNode
%property (nonatomic, strong) NSString *copiedComment;
%property (nonatomic, strong) NSURL *copiedURL;
%end

%hook ASDisplayNode
- (void)setFrame:(CGRect)frame {
    %orig;

    if (ytlBool(@"commentManager") && [[self valueForKey:@"_accessibilityIdentifier"] isEqualToString:@"id.comment.content.label"]) {
        if ([self isKindOfClass:NSClassFromString(@"ASTextNode")]) {
            ASTextNode *textNode = (ASTextNode *)self;

            NSString *comment;
            if ([textNode respondsToSelector:@selector(attributedText)]) {
                if (textNode.attributedText) comment = textNode.attributedText.string;
            }

            NSMutableArray *allObjects = self.supernodes.allObjects;
            for (ELMContainerNode *containerNode in allObjects) {
                if ([containerNode.description containsString:@"id.ui.comment_cell"] && comment) {
                    containerNode.copiedComment = comment;
                    break;
                }
            }
        }
    }

    if (ytlBool(@"postManager") && [self isKindOfClass:NSClassFromString(@"ELMExpandableTextNode")]) {
        ELMExpandableTextNode *expandableTextNode = (ELMExpandableTextNode *)self;

        if ([expandableTextNode.currentTextNode isKindOfClass:NSClassFromString(@"ASTextNode")]) {
            ASTextNode *textNode = (ASTextNode *)expandableTextNode.currentTextNode;

            NSString *text;
            if ([textNode respondsToSelector:@selector(attributedText)]) {
                if (textNode.attributedText) text = textNode.attributedText.string;
            }

            NSMutableArray *allObjects = self.supernodes.allObjects;
            for (ELMContainerNode *containerNode in allObjects) {
                if ([containerNode.description containsString:@"id.ui.backstage.original_post"] && text) {
                    containerNode.copiedComment = text;
                    break;
                }
            }
        }
    }
}
%end

%hook YTImageZoomNode
- (BOOL)gestureRecognizer:(id)arg1 shouldRecognizeSimultaneouslyWithGestureRecognizer:(id)arg2 {
    BOOL isImageLoaded = [[self valueForKey:@"_didLoadImage"] boolValue];
    if (ytlBool(@"postManager") && isImageLoaded) {
        ASDisplayNode *displayNode = (ASDisplayNode *)self;
        ASNetworkImageNode *imageNode = (ASNetworkImageNode *)self;
        NSURL *URL = imageNode.URL;

        NSMutableArray *allObjects = displayNode.supernodes.allObjects;
        for (ELMContainerNode *containerNode in allObjects) {
            if ([containerNode.description containsString:@"id.ui.backstage.original_post"]) {
                containerNode.copiedURL = URL;
                break;
            }
        }
    }

    return %orig;
}
%end

// Shared delegate for YTLite's injected long-press recognizers. YouTube's native
// community-post image tap-to-fullscreen is delivered as raw touchesBegan/Ended on
// the same _ASDisplayView we attach our long-press to. A delegate-less recognizer
// with the default delaysTouchesEnded=YES buffers those touches and suppresses the
// native single-tap (swipe survives because the carousel pan is on an ancestor
// scroll view). This delegate permits simultaneous recognition so our long-press
// coexists with — never blocks — the native tap.
// The gesture wars. We bolt long-presses onto YouTube's feed cells, and its own
// recognizers fight us for the touch. This one delegate arbitrates for all of them.
// Fair warning: gesture arbitration is decided at touch-BEGIN and can't be changed
// late -- everything here has to be set before the finger goes down.
@interface YTLGestureCoordinator : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation YTLGestureCoordinator
+ (instancetype)shared {
    static YTLGestureCoordinator *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [YTLGestureCoordinator new]; });
    return inst;
}
// Say yes to simultaneous recognition so we never BLOCK a native gesture --
// we want to coexist, not fight (that just breaks scrolling).
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }

// The finger-lift bug: YouTube's post cell opens the detail page on a plain TAP.
// Our long-press opens a menu, but on release the tap fired too and navigated out
// from behind the menu. Fix: make that tap wait for our long-press to FAIL. When the
// long-press wins (menu up) it never fails -> the tap never fires. A quick tap fails
// the long-press instantly, so normal tap-to-open still works. Only tap-vs-long-press,
// so pans/pinches are left alone and scrolling stays smooth.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [g isKindOfClass:[UILongPressGestureRecognizer class]] &&
           [other isKindOfClass:[UITapGestureRecognizer class]];
}
@end

// One place to birth all our long-presses so they behave identically.
// 0.4s beats YouTube's ~0.5s hold, so ours wins the race (see suppress below).
// cancelsTouchesInView=YES: the instant we recognize, the underlying touch is
// cancelled -- that's what stops the touch-driven nav on finger-lift. A quick tap
// never reaches 0.4s so it never trips this; tap-to-open is safe.
static void ytlConfigureLongPress(UILongPressGestureRecognizer *lp) {
    lp.minimumPressDuration = 0.4;
    lp.cancelsTouchesInView = YES;
    lp.delaysTouchesBegan = NO;
    lp.delaysTouchesEnded = NO;
    lp.delegate = [YTLGestureCoordinator shared];
}

// cancelsTouchesInView only stops TOUCH-driven navs -- it does nothing to other
// gesture recognizers, which track the touch on their own. So when our menu opens we
// also reach up the view chain and switch off YouTube's own taps AND long-presses:
// (a) so finger-lift can't fire a recognizer-driven nav, and (b) so YT's own context
// menu doesn't pop up next to ours. Ours are named "YTL…" -- leave those be. We fire
// at 0.4s, YT's at ~0.5s, so we kill its recognizer before it ever begins. Flip them
// back on after 0.6s so a normal tap/long-press works next time.
static void ytlSuppressAncestorTaps(UIView *view) {
    NSMutableArray<UIGestureRecognizer *> *toReenable = [NSMutableArray array];
    for (UIView *v = view; v; v = v.superview) {
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            BOOL isOurs = [gr.name hasPrefix:@"YTL"];
            BOOL isTapOrHold = [gr isKindOfClass:[UITapGestureRecognizer class]] ||
                               [gr isKindOfClass:[UILongPressGestureRecognizer class]];
            if (!isOurs && isTapOrHold && gr.isEnabled) {
                gr.enabled = NO;
                [toReenable addObject:gr];
            }
        }
    }
    if (toReenable.count)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ for (UIGestureRecognizer *r in toReenable) r.enabled = YES; });
}

#if defined(YTL_POST_DEBUG)
// Diagnostic: dump every gesture recognizer on `view` and each ancestor so we can see what
// actually drives the post-open navigation (class, name, enabled, state). Called before and
// after ytlSuppressAncestorTaps to confirm which recognizers we did/didn't disable.
static void ytlDumpRecognizers(UIView *view, NSString *tag) {
    int level = 0;
    for (UIView *v = view; v; v = v.superview, level++) {
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            NSMutableString *targets = [NSMutableString string];
            @try {
                for (id t in [gr valueForKey:@"_targets"]) {
                    id target = [t valueForKey:@"_target"];
                    if (target) [targets appendFormat:@"%@ ", NSStringFromClass([target class])];
                }
            } @catch (__unused id e) {}
            YTLDBG(@"recognizer[%@] L%d %@ name=%@ enabled=%d state=%ld view=%@ targets=[%@]",
                   tag, level, NSStringFromClass([gr class]), gr.name ?: @"(nil)",
                   gr.isEnabled, (long)gr.state, NSStringFromClass([v class]), targets);
        }
    }
}
#endif

// YES while some scroll view above us is moving. A hold that lands mid-scroll (say
// you grab the feed to stop it decelerating) shouldn't be read as "open my menu" --
// so every handler bails on this first.
static BOOL ytlEnclosingScrollActive(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (sv.isDragging || sv.isDecelerating) return YES;
        }
    }
    return NO;
}

// Depth-first search of the node tree for an image node whose frame contains `p`
// (p expressed in `node`'s own coordinate space). Node frames are in the supernode's
// space, so we translate the point as we descend.
// Minimum edge length (pt) for a node to count as a tappable post photo. Excludes
// avatars/badges/icons (~24–56pt) so tapping the header/"read more"/avatar doesn't open
// the profile picture — only a real attached image (which is large) qualifies.
static const CGFloat kYTLMinImageEdge = 100.0;

// Finds the image URL strictly UNDER `p` (in `node`'s coordinate space) by frame
// containment, descending only into children whose frame contains the point.
static NSURL *imageURLAtPoint(ASDisplayNode *node, CGPoint p, int depth) {
    if (!node || depth > 14) return nil;
    for (ASDisplayNode *child in node.yogaChildren) {
        CGRect f = child.frame;
        if (CGRectIsEmpty(f) || !CGRectContainsPoint(f, p)) continue;
        CGPoint cp = CGPointMake(p.x - f.origin.x, p.y - f.origin.y);
        NSURL *deeper = imageURLAtPoint(child, cp, depth + 1);
        if (deeper) return deeper;
        NSURL *own = nodeImageURL(child);
        if (own && f.size.width >= kYTLMinImageEdge && f.size.height >= kYTLMinImageEdge)
            return own;
    }
    return nil;
}

// Finds the image URL under `point` (in rootView's coords). Uses UIView hit-testing to
// reach the tapped element (robust to nested collection cells / scroll offsets, e.g. the
// "Posts from …'s Community" carousel), then requires the point to actually fall inside a
// large-enough image's frame. Precise: tapping text/"read more"/empty area or an avatar
// yields nil, so only tapping the attached photo opens the viewer.
// A photo attachment we should open. Excludes video thumbnails (i.ytimg.com/vi/…), which
// are video attachments — tapping those should play the video, not open a still image.
static BOOL ytlIsPostPhotoURL(NSURL *u) {
    if (!u) return NO;
    NSString *s = u.absoluteString;
    if ([s containsString:@"i.ytimg.com"] || [s containsString:@"/vi/"]) return NO;
    return YES;
}

static NSURL *ytlImageURLForView(UIView *rootView, CGPoint point) {
    UIView *v = [rootView hitTest:point withEvent:nil];
    for (int i = 0; v && i < 12; i++) {
        if ([v respondsToSelector:@selector(keepalive_node)]) {
            ASDisplayNode *node = (ASDisplayNode *)[(id)v keepalive_node];
            if (node) {
                CGPoint p = [rootView convertPoint:point toView:v];
                NSURL *inner = imageURLAtPoint(node, p, 0);
                if (inner) return ytlIsPostPhotoURL(inner) ? inner : nil;
                // The hit view itself may be the (layer-backed) image node.
                NSURL *own = nodeImageURL(node);
                if (own && v.bounds.size.width >= kYTLMinImageEdge &&
                    v.bounds.size.height >= kYTLMinImageEdge && CGRectContainsPoint(v.bounds, p))
                    return ytlIsPostPhotoURL(own) ? own : nil;
            }
        }
        v = v.superview;
    }
    return nil;
}

// Self-contained fullscreen zoomable image viewer. YouTube's native
// tap-to-fullscreen for community-post images (didTapBackstageImageView: ->
// YTBackstageFullscreenImageViewController) is gated behind the server hot-config
// experiment iosPostImageGalleryStart and does nothing when that experiment is off.
// The current closed-source YTLite 5.2.1 solves this the same way: it ships its own
// viewer (DVNImageViewController) instead of relying on the native path.
// One zoomable page in the gallery: a UIScrollView holding an aspect-fit UIImageView that
// loads its URL (full-res =s0) with pinch + double-tap zoom. Reports zoom changes so the
// container can disable paging/dismiss while zoomed.
@interface YTLZoomView : UIScrollView <UIScrollViewDelegate>
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSData *imageData;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) BOOL fullLoaded;
@property (nonatomic, copy) void (^onZoomChanged)(void);
- (instancetype)initWithFrame:(CGRect)frame url:(NSURL *)url;
- (BOOL)isZoomedIn;
@end

@implementation YTLZoomView

- (instancetype)initWithFrame:(CGRect)frame url:(NSURL *)url {
    if ((self = [super initWithFrame:frame])) {
        _url = url;
        self.delegate = self;
        self.minimumZoomScale = 1.0;
        self.maximumZoomScale = 4.0;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _spinner.color = [UIColor whiteColor];
        _spinner.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [_spinner startAnimating];
        [self addSubview:_spinner];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];

        [self load];
    }
    return self;
}

// Progressive load: a fast ~2048px preview appears almost immediately, then the =s0
// original replaces it (and its bytes are kept for full-res save). Avoids the long wait
// on huge originals while still ending up full resolution.
- (void)load {
    NSString *base = self.url.absoluteString;
    NSURL *previewURL = [NSURL URLWithString:ytSizedURLString(base, @"=s2048")] ?: self.url;
    NSURL *fullURL = self.url;
    __weak typeof(self) weakSelf = self;

    [[[NSURLSession sharedSession] dataTaskWithURL:previewURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !image || self.fullLoaded) return;
            [self.spinner stopAnimating];
            self.imageView.image = image;
            if (!self.imageData) self.imageData = data; // fallback for save until full arrives
        });
    }] resume];

    [[[NSURLSession sharedSession] dataTaskWithURL:fullURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !image) return;
            [self.spinner stopAnimating];
            self.fullLoaded = YES;
            self.imageData = data;
            self.imageView.image = image;
        });
    }] resume];
}

- (BOOL)isZoomedIn { return self.zoomScale > self.minimumZoomScale + 0.01; }

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return self.imageView; }

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    CGSize b = scrollView.bounds.size, c = scrollView.contentSize;
    CGFloat ox = c.width < b.width ? (b.width - c.width) / 2.0 : 0;
    CGFloat oy = c.height < b.height ? (b.height - c.height) / 2.0 : 0;
    self.imageView.center = CGPointMake(c.width / 2.0 + ox, c.height / 2.0 + oy);
    if (self.onZoomChanged) self.onZoomChanged();
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    if (self.onZoomChanged) self.onZoomChanged();
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    if ([self isZoomedIn]) {
        [self setZoomScale:self.minimumZoomScale animated:YES];
    } else {
        CGPoint pt = [g locationInView:self.imageView];
        CGFloat scale = 2.5;
        CGSize size = self.bounds.size;
        CGRect rect = CGRectMake(pt.x - (size.width / scale) / 2.0, pt.y - (size.height / scale) / 2.0, size.width / scale, size.height / scale);
        [self zoomToRect:rect animated:YES];
    }
}

@end

// Self-contained fullscreen gallery. YouTube's native tap-to-fullscreen for community-post
// images (didTapBackstageImageView: -> YTBackstageFullscreenImageViewController) is gated
// behind the server hot-config experiment iosPostImageGalleryStart and does nothing when
// off. The current closed-source YTLite 5.2.1 ships its own viewer for the same reason.
// Horizontal paging browses multiple images in a post; each page zooms independently.
@interface YTLImageViewer : UIViewController <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSArray<NSURL *> *urls;
@property (nonatomic, assign) NSInteger startIndex;
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic, strong) NSMutableArray<YTLZoomView *> *pages;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, assign) BOOL didInitialLayout;
+ (void)presentWithURLs:(NSArray<NSURL *> *)urls index:(NSInteger)index from:(UIViewController *)presenter;
+ (void)presentWithURL:(NSURL *)url from:(UIViewController *)presenter;
@end

@implementation YTLImageViewer

+ (void)presentWithURL:(NSURL *)url from:(UIViewController *)presenter {
    if (!url) return;
    [self presentWithURLs:@[url] index:0 from:presenter];
}

+ (void)presentWithURLs:(NSArray<NSURL *> *)urls index:(NSInteger)index from:(UIViewController *)presenter {
    if (urls.count == 0) return;
    UIViewController *host = presenter;
    if (!host) {
        UIWindow *keyWindow = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;
        host = keyWindow.rootViewController;
    }
    if (!host) return;
    while (host.presentedViewController) host = host.presentedViewController;
    // Guard against double-present (a tap can be seen by more than one matching view).
    if ([host isKindOfClass:[YTLImageViewer class]]) return;

    // Normalize every URL to full-res (=s0).
    NSMutableArray<NSURL *> *full = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) {
        NSURL *n = [NSURL URLWithString:ytMaxResURLString(u.absoluteString)] ?: u;
        [full addObject:n];
    }
    YTLImageViewer *vc = [YTLImageViewer new];
    vc.urls = full;
    vc.startIndex = MAX(0, MIN((NSInteger)full.count - 1, index));
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
#if defined(YTL_POST_DEBUG)
    YTLDBG(@"presenting gallery: %lu image(s), index %ld, from %@", (unsigned long)full.count, (long)vc.startIndex, NSStringFromClass([host class]));
#endif
    [host presentViewController:vc animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.pager = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.pager.pagingEnabled = YES;
    self.pager.showsHorizontalScrollIndicator = NO;
    self.pager.showsVerticalScrollIndicator = NO;
    self.pager.alwaysBounceVertical = NO;
    self.pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.pager.delegate = self;
    [self.view addSubview:self.pager];

    self.pages = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSURL *url in self.urls) {
        YTLZoomView *page = [[YTLZoomView alloc] initWithFrame:CGRectZero url:url];
        page.onZoomChanged = ^{ [weakSelf currentPageZoomChanged]; };
        [self.pager addSubview:page];
        [self.pages addObject:page];
    }

    self.closeButton = [self chromeButtonWithSystemImage:@"xmark" action:@selector(closeTapped)];
    self.saveButton = [self chromeButtonWithSystemImage:@"square.and.arrow.down" action:@selector(saveTapped)];
    self.shareButton = [self chromeButtonWithSystemImage:@"square.and.arrow.up" action:@selector(shareTapped)];
    [self.view addSubview:self.closeButton];
    [self.view addSubview:self.saveButton];
    [self.view addSubview:self.shareButton];

    self.counterLabel = [[UILabel alloc] init];
    self.counterLabel.textColor = [UIColor whiteColor];
    self.counterLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    self.counterLabel.hidden = (self.urls.count < 2);
    [self.view addSubview:self.counterLabel];

    // Swipe up/down to dismiss (when not zoomed and drag is mostly vertical).
    UIPanGestureRecognizer *dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDismissPan:)];
    dismissPan.delegate = self;
    [self.view addGestureRecognizer:dismissPan];
}

- (UIButton *)chromeButtonWithSystemImage:(NSString *)name action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:name] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    b.layer.cornerRadius = 20.0;
    b.frame = CGRectMake(0, 0, 40, 40);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    self.pager.frame = self.view.bounds;
    for (NSInteger i = 0; i < (NSInteger)self.pages.count; i++) {
        self.pages[i].frame = CGRectMake(i * W, 0, W, H);
    }
    self.pager.contentSize = CGSizeMake(W * self.pages.count, H);
    if (!self.didInitialLayout) {
        self.didInitialLayout = YES;
        self.pager.contentOffset = CGPointMake(self.startIndex * W, 0);
        [self updateCounter];
    }
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat top = safe.top + 8;
    CGFloat right = W - safe.right - 8 - 40;
    self.closeButton.frame = CGRectMake(safe.left + 8, top, 40, 40);
    self.shareButton.frame = CGRectMake(right, top, 40, 40);
    self.saveButton.frame = CGRectMake(right - 48, top, 40, 40);
    self.counterLabel.frame = CGRectMake(W / 2.0 - 60, top, 120, 40);
}

- (NSInteger)currentIndex {
    CGFloat W = self.view.bounds.size.width;
    if (W <= 0) return self.startIndex;
    NSInteger i = (NSInteger)lround(self.pager.contentOffset.x / W);
    return MAX(0, MIN((NSInteger)self.pages.count - 1, i));
}

- (YTLZoomView *)currentPage {
    NSInteger i = [self currentIndex];
    return (i >= 0 && i < (NSInteger)self.pages.count) ? self.pages[i] : nil;
}

- (void)updateCounter {
    if (self.urls.count < 2) return;
    self.counterLabel.text = [NSString stringWithFormat:@"%ld / %lu", (long)[self currentIndex] + 1, (unsigned long)self.urls.count];
}

// Disable paging while a page is zoomed in so panning moves within the image.
- (void)currentPageZoomChanged {
    self.pager.scrollEnabled = ![[self currentPage] isZoomedIn];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.pager) [self updateCounter];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.pager) return;
    // Reset zoom on pages that scrolled off-screen.
    NSInteger cur = [self currentIndex];
    for (NSInteger i = 0; i < (NSInteger)self.pages.count; i++) {
        if (i != cur && [self.pages[i] isZoomedIn]) [self.pages[i] setZoomScale:self.pages[i].minimumZoomScale animated:NO];
    }
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]] && g.view == self.view) {
        if ([[self currentPage] isZoomedIn]) return NO;
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self.view];
        return fabs(v.y) > fabs(v.x);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)handleDismissPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            self.pager.scrollEnabled = NO; // don't page while dragging to dismiss
            break;
        case UIGestureRecognizerStateChanged: {
            self.pager.transform = CGAffineTransformMakeTranslation(0, t.y);
            CGFloat progress = MIN(1.0, fabs(t.y) / 320.0);
            self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0 - progress * 0.75];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGPoint vel = [g velocityInView:self.view];
            if (fabs(t.y) > 120.0 || fabs(vel.y) > 800.0) {
                // Fade out from wherever the drag left it — no directional re-animation.
                [UIView animateWithDuration:0.2 animations:^{
                    self.view.alpha = 0.0;
                } completion:^(BOOL finished) {
                    [self dismissViewControllerAnimated:NO completion:nil];
                }];
            } else {
                [UIView animateWithDuration:0.25 animations:^{
                    self.pager.transform = CGAffineTransformIdentity;
                    self.view.backgroundColor = [UIColor blackColor];
                } completion:^(BOOL finished) {
                    self.pager.scrollEnabled = YES;
                }];
            }
            break;
        }
        default: break;
    }
}

- (void)saveTapped {
    YTLZoomView *page = [self currentPage];
    UIImage *image = page.imageView.image;
    NSData *data = page.imageData;
    if (!image && !data) return;
    ytlEnsurePhotosAuth(^(BOOL granted) {
        if (!granted) { [self showSaveResult:NO error:[NSError errorWithDomain:@"YTLite" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Photos access denied"}]]; return; }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            // Save the ORIGINAL bytes when we have them. creationRequestForAssetFromImage:
            // re-encodes the UIImage and chokes with PHPhotosErrorInvalidResource (3302) on
            // some images -- addResourceWithType: writes the bytes as-is and just works.
            if (data) {
                PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
                [req addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
            } else {
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            }
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showSaveResult:success error:error]; });
        }];
    });
}

- (void)showSaveResult:(BOOL)success error:(NSError *)error {
#if defined(YTL_POST_DEBUG)
    YTLDBG(@"viewer save success=%d error=%@", success, error.localizedDescription ?: @"(none)");
#endif
    NSString *msg = success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareTapped {
    UIImage *image = [self currentPage].imageView.image;
    if (!image) return;
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[image] applicationActivities:nil];
    av.popoverPresentationController.sourceView = self.shareButton;
    av.popoverPresentationController.sourceRect = self.shareButton.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

@end

// Appends any community-post photo URLs found in a string (a node/element/renderer
// description) to `out`, in order, deduped by =s0-normalized form. Post attachment images
// carry a "-fcrop64" crop directive, which distinguishes them from avatars/emoji/badges.
// This reads the post's model text, so it finds ALL images even ones not yet realized in
// the lazily-loaded carousel.
static void ytlAddPhotoURLsFromString(NSString *s, NSMutableArray<NSURL *> *out) {
    if (s.length == 0) return;
    NSScanner *sc = [NSScanner scannerWithString:s];
    sc.charactersToBeSkipped = nil;
    NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@" \t\n\r\f\"'<>(){}[]\\|,;"];
    while (![sc isAtEnd]) {
        if (![sc scanUpToString:@"https://" intoString:NULL]) break;
        NSString *candidate = nil;
        if (![sc scanUpToCharactersFromSet:stops intoString:&candidate] || candidate.length == 0) continue;
        if (![candidate containsString:@"ggpht.com"] && ![candidate containsString:@"googleusercontent.com"]) continue;
        if (![candidate containsString:@"fcrop64"]) continue; // exclude avatars/badges
        if (out.count >= 30) break;
        NSString *norm = ytMaxResURLString(candidate);
        BOOL dup = NO;
        for (NSURL *u in out) { if ([ytMaxResURLString(u.absoluteString) isEqualToString:norm]) { dup = YES; break; } }
        if (!dup) { NSURL *nu = [NSURL URLWithString:norm]; if (nu) [out addObject:nu]; }
    }
}


// Opens the gallery for the tapped image. If a multi-image group containing it was cached
// at feed time (from the elementRenderer's EML bytes), pages the whole ordered group
// starting on the tapped image; otherwise shows just the tapped image.
static void ytlPresentGallery(NSURL *tapped, UIViewController *host) {
    if (!tapped) return;
    NSString *tappedNorm = ytMaxResURLString(tapped.absoluteString);
    NSMutableArray<NSURL *> *all = [NSMutableArray array];
    NSInteger idx = 0;

    NSArray<NSString *> *group = ytlImageGroupContaining(tappedNorm);
    if (group.count >= 2) {
        for (NSString *g in group) { NSURL *u = [NSURL URLWithString:g]; if (u) [all addObject:u]; }
        NSInteger gi = [group indexOfObject:tappedNorm];
        idx = (gi == NSNotFound) ? 0 : gi;
    } else {
        [all addObject:([NSURL URLWithString:tappedNorm] ?: tapped)];
    }
#if defined(YTL_POST_DEBUG)
    YTLDBG(@"gallery: group=%lu total=%lu index=%ld", (unsigned long)group.count, (unsigned long)all.count, (long)idx);
#endif
    [YTLImageViewer presentWithURLs:all index:idx from:host];
}

// Matches the post CONTENT container(s) — not the backstage action buttons
// (post_menu_button / comment_button / like_button / dislike_button, which also contain
// "backstage"). YouTube added an outer "id.ui.backstage.post" wrapper alongside the older
// "id.ui.backstage.original_post"; the identifier is printed as "…post>"/"…original_post>"
// in the node description, so we match with the trailing '>' to exclude the "…post_*" buttons.
static BOOL ytlDescIsPost(NSString *desc) {
    if (!desc) return NO;
    return [desc containsString:@"id.ui.backstage.post>"] ||
           [desc containsString:@"id.ui.backstage.original_post>"] ||
           [desc containsString:@"post_base_wrapper"] ||
           [desc containsString:@"sharedpost"];
}

%hook _ASDisplayView
- (void)setKeepalive_node:(id)arg1 {
    %orig;

    NSString *desc = [self description];

#if defined(YTL_POST_DEBUG)
    // Diagnostic: surface the real runtime identifier of post-like feed cells and whether
    // ytlDescIsPost() still matches them (so we can tell a matcher miss from a URL miss).
    if (ytlBool(@"postManager") &&
        ([desc rangeOfString:@"backstage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [desc rangeOfString:@"post" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [desc rangeOfString:@"shared" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        NSString *trimmed = desc.length > 700 ? [desc substringToIndex:700] : desc;
        YTLDBG(@"keepalive post-like (match=%d): %@", ytlDescIsPost(desc) ? 1 : 0, trimmed);
    }

#endif

    NSArray *gesturesInfo = @[
        @{@"selector": @"savePFP:", @"text": @"ELMImageNode-View", @"key": @(ytlBool(@"saveProfilePhoto"))},
        @{@"selector": @"commentManager:", @"text": @"id.ui.comment_cell", @"key": @(ytlBool(@"commentManager"))}
    ];

    for (NSDictionary *gestureInfo in gesturesInfo) {
        SEL selector = NSSelectorFromString(gestureInfo[@"selector"]);

        if ([gestureInfo[@"key"] boolValue] && [desc containsString:gestureInfo[@"text"]]) {
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:selector];
            ytlConfigureLongPress(longPress);
            [self addGestureRecognizer:longPress];
            break;
        }
    }

    // Community post: attach the long-press action menu (Open Image / Save / Copy). We
    // deliberately do NOT hook the tap — YouTube's feed now opens the post detail on a cell
    // tap (a lazily-added recognizer on the "id.ui.backstage.post" wrapper), and fighting it
    // is unreliable; the paid YTLite 5.x also opens its viewer from this long-press menu.
    if (ytlBool(@"postManager") && ytlDescIsPost(desc)) {
        // setKeepalive_node: is called repeatedly on reused cells; only attach once per view.
        BOOL already = NO;
        for (UIGestureRecognizer *gr in self.gestureRecognizers) {
            if ([gr.name isEqualToString:@"YTLPost"]) { already = YES; break; }
        }
        if (!already) {
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(postManager:)];
            ytlConfigureLongPress(longPress);
            longPress.name = @"YTLPost";
            [self addGestureRecognizer:longPress];
        }
    }

    // Queue: attach a long-press to feed video cells (home/search use YTVideoWithContextNode)
    // so it can offer "Add to queue". The videoID is read from the thumbnail URL at press time.
    if (ytlBool(@"enableQueue") && [desc containsString:@"YTVideoWithContextNode"]) {
        BOOL already = NO;
        for (UIGestureRecognizer *gr in self.gestureRecognizers) {
            if ([gr.name isEqualToString:@"YTLQueue"]) { already = YES; break; }
        }
        if (!already) {
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ytlQueueLongPress:)];
            ytlConfigureLongPress(longPress);
            longPress.name = @"YTLQueue";
            [self addGestureRecognizer:longPress];
        }
    }
}

%new
- (void)savePFP:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {

        ASNetworkImageNode *imageNode = (ASNetworkImageNode *)self.keepalive_node;
        NSString *URLString = imageNode.URL.absoluteString;
        if (URLString) {
            NSRange sizeRange = [URLString rangeOfString:@"=s"];
            if (sizeRange.location != NSNotFound) {
                NSRange dashRange = [URLString rangeOfString:@"-" options:0 range:NSMakeRange(sizeRange.location, URLString.length - sizeRange.location)];
                if (dashRange.location != NSNotFound) {
                    NSString *newURLString = [URLString stringByReplacingCharactersInRange:NSMakeRange(sizeRange.location + 2, dashRange.location - sizeRange.location - 2) withString:@"1024"];
                    NSURL *PFPURL = [NSURL URLWithString:newURLString];

                    UIImage *image = [UIImage imageWithData:[NSData dataWithContentsOfURL:PFPURL]];
                    if (image) {
                        YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];
    
                        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveProfilePicture") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);

                            [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Saved") firstResponder:self.keepalive_node.closestViewController] send];
                        }]];

                        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyProfilePicture") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
                            [UIPasteboard generalPasteboard].image = image;
                            [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.keepalive_node.closestViewController] send];
                        }]];

                        [sheetController presentFromViewController:self.keepalive_node.closestViewController animated:YES completion:nil];
                    }
                }
            }
        }
    }
}

%new
- (void)postManager:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    if (ytlEnclosingScrollActive(self)) return; // ignore holds that begin a scroll
#if defined(YTL_POST_DEBUG)
    ytlDumpRecognizers(self, @"before");
#endif
    ytlSuppressAncestorTaps(self); // don't let the finger-lift also open the post
#if defined(YTL_POST_DEBUG)
    ytlDumpRecognizers(self, @"after");
#endif
    ELMContainerNode *containerNode = (ELMContainerNode *)self.keepalive_node;
    NSString *text = containerNode.copiedComment;
    // The image under the finger — the long-press location is valid because the touch is
    // still down. Fall back to a captured URL, then the first image in the post's subtree.
    NSURL *URL = ytlImageURLForView(self, [sender locationInView:self])
                 ?: containerNode.copiedURL
                 ?: findImageURLInNode((ASDisplayNode *)containerNode, 0);

    YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

    if (URL) {
        // Open the actual full-resolution attached image (paged gallery for multi-image
        // posts) — not a screenshot of the post.
        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:@"Open Image" iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
            ytlPresentGallery(URL, containerNode.closestViewController);
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveCurrentImage") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
            downloadImageFromURL(containerNode.closestViewController, URL, YES);
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCurrentImage") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
            downloadImageFromURL(containerNode.closestViewController, URL, NO);
        }]];
    }

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyPostText") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
        if (text) {
            [UIPasteboard generalPasteboard].string = text;
            [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
        }
    }]];

    [sheetController presentFromViewController:containerNode.closestViewController animated:YES completion:nil];
}

// The one entry point for the whole queue: hold a feed video and up comes our menu
// -- Add (or Remove, if it's already in), and View queue once there's something in it.
// WARNING: we can't fold YouTube's own long-press menu in here. On these cells that
// menu lives inside AsyncDisplayKit and only fires from a LIVE gesture -- there's no
// method to call to summon it after the fact (believe me, I looked). Its actions
// still live on the cell's ⋯ button, so nothing's actually lost.
%new
- (void)ytlQueueLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    if (ytlEnclosingScrollActive(self)) return; // ignore holds that begin a scroll

    ytlSuppressAncestorTaps(self); // our menu wins — suppress the cell's tap + native long-press

    NSURL *thumb = ytlImageURLForView(self, [sender locationInView:self])
                   ?: findImageURLInNode((ASDisplayNode *)self.keepalive_node, 0);
    NSString *videoID = ytlVideoIDFromThumbnailURL(thumb);
    if (!videoID.length) return;

    YTLQueueManager *q = [YTLQueueManager shared];
    id responder = [%c(YTUIUtils) topViewControllerForPresenting];
    YTDefaultSheetController *sheet = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

    if ([q contains:videoID]) {
        [sheet addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"RemoveFromQueue") iconImage:YTImageNamed(@"yt_outline_list_remove_24pt") style:0 handler:^ {
            [q remove:videoID];
        }]];
    } else {
        [sheet addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"AddToQueue") iconImage:YTImageNamed(@"yt_outline_list_queue_24pt") style:0 handler:^ {
            // "Add to queue" ALWAYS just queues -- it never hijacks the player. If a video is
            // playing, engage so the queue follows it; if nothing's playing it just waits in the
            // queue until you start it from View queue (tap an item).
            [q enqueue:videoID];
            if (ytlVideoIsActive()) gYTLQueueEngaged = YES;
            NSString *msg = [NSString stringWithFormat:@"%@ (%lu)", LOC(@"AddedToQueue"), (unsigned long)q.count];
            // Quick flash (~0.8s) -- "Added to queue" doesn't need to linger like the default ~4s.
            [[%c(YTToastResponderEvent) eventWithMessage:msg infoType:0 duration:0.8 firstResponder:responder] send];
        }]];
    }

    if (q.count) {
        [sheet addAction:[%c(YTActionSheetAction) actionWithTitle:[NSString stringWithFormat:@"%@ (%lu)", LOC(@"ViewQueue"), (unsigned long)q.count] iconImage:YTImageNamed(@"yt_outline_list_view_24pt") style:0 handler:^ {
            ytlPresentQueueViewer();
        }]];
    }

    [sheet presentFromViewController:responder animated:YES completion:nil];
}

%new
- (void)commentManager:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {
        if (ytlEnclosingScrollActive(self)) return;
        ELMContainerNode *containerNode = (ELMContainerNode *)self.keepalive_node;
        NSString *comment = containerNode.copiedComment;

        CALayer *layer = self.layer;
        UIColor *backgroundColor = containerNode.closestViewController.view.backgroundColor;

        YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCommentText") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
            if (comment) {
                [UIPasteboard generalPasteboard].string = comment;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            }
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveCommentAsImage") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAssetFromImage:image];
                    request.creationDate = [NSDate date];
                } completionHandler:^(BOOL success, NSError *error) {
                    NSString *message = success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription];
                    [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:containerNode.closestViewController] send];
                }];
            });
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCommentAsImage") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [UIPasteboard generalPasteboard].image = image;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            });
        }]];

        [sheetController presentFromViewController:containerNode.closestViewController animated:YES completion:nil];
    }
}
%end

// ============================================================================
// PIVOT BAR / TABS
//   tab removal, Explore re-add, indicators/labels, long-press manage, startup tab
// ============================================================================

// Remove Tabs
%hook YTPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    NSMutableArray <YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];

    NSDictionary *identifiersToRemove = @{
        @"FEshorts": @[@(ytlBool(@"removeShorts")), @(ytlBool(@"reExplore"))],
        @"FEsubscriptions": @[@(ytlBool(@"removeSubscriptions"))],
        @"FEuploads": @[@(ytlBool(@"removeUploads"))],
        @"FElibrary": @[@(ytlBool(@"removeLibrary"))]
    };

    for (NSString *identifier in identifiersToRemove) {
        NSArray *removeValues = identifiersToRemove[identifier];
        BOOL shouldRemoveItem = [removeValues containsObject:@(YES)];

        NSUInteger index = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderer, NSUInteger idx, BOOL *stop) {
            if ([identifier isEqualToString:@"FEuploads"]) {
                return shouldRemoveItem && [[[renderer pivotBarIconOnlyItemRenderer] pivotIdentifier] isEqualToString:identifier];
            } else {
                return shouldRemoveItem && [[[renderer pivotBarItemRenderer] pivotIdentifier] isEqualToString:identifier];
            }
        }];

        if (index != NSNotFound) {
            [items removeObjectAtIndex:index];
        }
    }
    
    NSUInteger exploreIndex = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
        return [[[renderers pivotBarItemRenderer] pivotIdentifier] isEqualToString:[%c(YTIBrowseRequest) browseIDForExploreTab]];
    }];

    if (exploreIndex == NSNotFound && (ytlBool(@"reExplore") || ytlBool(@"addExplore"))) {
        YTIPivotBarSupportedRenderers *exploreTab = [%c(YTIPivotBarRenderer) pivotSupportedRenderersWithBrowseId:[%c(YTIBrowseRequest) browseIDForExploreTab] title:LOC(@"Explore") iconType:292];
        [items insertObject:exploreTab atIndex:1];
    }

    %orig;
}
%end

// Hide Tab Bar Indicators
%hook YTPivotBarIndicatorView
- (void)setFillColor:(id)arg1 { %orig(ytlBool(@"removeIndicators") ? [UIColor clearColor] : arg1); }
- (void)setBorderColor:(id)arg1 { %orig(ytlBool(@"removeIndicators") ? [UIColor clearColor] : arg1); }
%end

// Hide Tab Labels
%hook YTPivotBarItemView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    %orig;

    if (ytlBool(@"removeLabels")) {
        [self.navigationButton setTitle:@"" forState:UIControlStateNormal];
        [self.navigationButton setSizeWithPaddingAndInsets:NO];
    }

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(manageTab:)];
    longPress.minimumPressDuration = 0.3;
    if ([self.renderer.pivotIdentifier isEqualToString:@"FEwhat_to_watch"]) [self addGestureRecognizer:longPress];
}

%new
- (void)manageTab:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ytlBool(@"removeLibrary") ? ytlSetBool(NO, @"removeLibrary") : ytlSetBool(YES, @"removeLibrary");
        [[[%c(YTHeaderContentComboViewController) alloc] init] refreshPivotBar];
        [[%c(YTToastResponderEvent) eventWithMessage:ytlBool(@"removeLibrary") ? LOC(@"LibraryRemoved") : LOC(@"LibraryAdded") firstResponder:self.delegate] send];
    }
}
%end

// Startup Tab
BOOL isTabSelected = NO;
%hook YTPivotBarViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!isTabSelected && !ytlBool(@"shortsOnlyMode")) {
        NSArray *pivotIdentifiers = @[@"FEwhat_to_watch", @"FEexplore", @"FEshorts", @"FEsubscriptions", @"FElibrary"];
        [self selectItemWithPivotIdentifier:pivotIdentifiers[ytlInt(@"pivotIndex")]];
        isTabSelected = YES;
    }

    if (ytlBool(@"shortsOnlyMode")) {
        [self selectItemWithPivotIdentifier:@"FEshorts"];
        [self.parentViewController hidePivotBar];
    }
}
%end

%hook YTAppViewControllerImpl
- (void)showPivotBar {
    if (!ytlBool(@"shortsOnlyMode")) {
        %orig;

        isOverlayShown = YES;
    }
}
%end

%hook YTReelWatchRootViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (ytlBool(@"shortsOnlyMode")) {
        [self.navigationController.parentViewController hidePivotBar];
    }
}
%end

// ============================================================================
// ENGAGEMENT PANEL: COPY VIDEO INFO BUTTON
// ============================================================================

%hook YTEngagementPanelView
- (void)layoutSubviews {
    %orig;

    if (ytlBool(@"copyVideoInfo") && [self.panelIdentifier.identifierString isEqualToString:@"video-description-ep-identifier"]) {
        YTQTMButton *copyInfoButton = [%c(YTQTMButton) iconButton];
        copyInfoButton.accessibilityLabel = LOC(@"CopyVideoInfo");
        [copyInfoButton setTag:999];
        [copyInfoButton enableNewTouchFeedback];
        [copyInfoButton setImage:YTImageNamed(@"yt_outline_copy_24pt") forState:UIControlStateNormal];
        [copyInfoButton setTintColor:[UIColor labelColor]];
        [copyInfoButton setTranslatesAutoresizingMaskIntoConstraints:false];
        [copyInfoButton addTarget:self action:@selector(didTapCopyInfoButton:) forControlEvents:UIControlEventTouchUpInside];

        if (self.headerView && ![self.headerView viewWithTag:999]) {
            [self.headerView addSubview:copyInfoButton];

            [NSLayoutConstraint activateConstraints:@[
                [copyInfoButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-48],
                [copyInfoButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
                [copyInfoButton.widthAnchor constraintEqualToConstant:40.0],
                [copyInfoButton.heightAnchor constraintEqualToConstant:40.0],
            ]];
        }
    }
}

%new
- (void)didTapCopyInfoButton:(UIButton *)sender {
    YTPlayerViewController *playerVC = self.resizeDelegate.parentViewController.parentViewController.parentViewController.playerViewController;
    NSString *title = playerVC.playerResponse.playerData.videoDetails.title;
    NSString *shortDescription = playerVC.playerResponse.playerData.videoDetails.shortDescription;

    YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyTitle") iconImage:YTImageNamed(@"yt_outline_text_box_24pt") style:0 handler:^ {
        [UIPasteboard generalPasteboard].string = title;
        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.resizeDelegate] send];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyDescription") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
        [UIPasteboard generalPasteboard].string = shortDescription;
        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.resizeDelegate] send];
    }]];

    [sheetController presentFromViewController:self.resizeDelegate animated:YES completion:nil];
}
%end

// ============================================================================
// SPEEDMASTER (long-press to temporarily change playback speed)
// ============================================================================

CGFloat rateBeforeSpeedmaster = 1.0;

static void manageSpeedmasterYTLite(UILongPressGestureRecognizer *gesture, YTMainAppVideoPlayerOverlayViewController *delegate, YTInlinePlayerScrubUserEducationView *edu) {
    NSArray *speedLabels = @[@0, @2.0, @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];

    YTLabel *label = [edu valueForKey:@"_userEducationLabel"];
    edu.labelType = 1;
    [label setValue:[NSString stringWithFormat:@"%@: %@×", LOC(@"PlaybackSpeed"), speedLabels[ytlInt(@"speedIndex")]] forKey:@"text"];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        rateBeforeSpeedmaster = delegate.currentPlaybackRate;
        [delegate setPlaybackRate:[speedLabels[ytlInt(@"speedIndex")] floatValue]];
        [edu setVisible:YES];
    }

    else if (gesture.state == UIGestureRecognizerStateEnded) {
        [delegate setPlaybackRate:rateBeforeSpeedmaster];
        [edu setVisible:NO];
    }
}

%hook YTMainAppVideoPlayerOverlayView
- (void)setSeekAnywherePanGestureRecognizer:(id)arg1 {
    if (ytlInt(@"speedIndex") == 0) return %orig;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(speedmasterYtLite:)];
    longPress.minimumPressDuration = 0.3;
    if (ytlInt(@"speedIndex") != 0) [self addGestureRecognizer:longPress];
}

%new
- (void)speedmasterYtLite:(UILongPressGestureRecognizer *)gesture {
    YTInlinePlayerScrubUserEducationView *edu = self.scrubUserEducationView;
    manageSpeedmasterYTLite(gesture, self.delegate, edu);
}
%end

%hook YTSpeedmasterController
- (void)speedmasterDidLongPressWithRecognizer:(UILongPressGestureRecognizer *)gesture {
    if (ytlInt(@"speedIndex") == 0) return;
    if (ytlInt(@"speedIndex") == 1) return %orig;

    YTMainAppVideoPlayerOverlayViewController *delegate = [self valueForKey:@"_delegate"];
    YTInlinePlayerScrubUserEducationView *edu = (YTInlinePlayerScrubUserEducationView *)delegate.videoPlayerOverlayView.scrubUserEducationView;
    manageSpeedmasterYTLite(gesture, delegate, edu);
}
%end

// ============================================================================
// MISCELLANEOUS (RTL formatting fix, album-cover CDN host fix)
// ============================================================================

// Disable Right-To-Left Formatting
%hook NSParagraphStyle
+ (NSWritingDirection)defaultWritingDirectionForLanguage:(id)lang { return ytlBool(@"disableRTL") ? NSWritingDirectionLeftToRight : %orig; }
+ (NSWritingDirection)_defaultWritingDirection { return ytlBool(@"disableRTL") ? NSWritingDirectionLeftToRight : %orig; }
%end

// Fix Albums For Russian Users
static NSURL *newCoverURL(NSURL *originalURL) {
    NSDictionary <NSString *, NSString *> *hostsToReplace = @{
        @"yt3.ggpht.com": @"yt4.ggpht.com",
        @"yt3.googleusercontent.com": @"yt4.googleusercontent.com",
    };

    NSString *const replacement = hostsToReplace[originalURL.host];
    if (ytlBool(@"fixAlbums") && replacement) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:originalURL resolvingAgainstBaseURL:NO];
        components.host = replacement;
        return components.URL;
    }
    return originalURL;
}

%hook YTImageSelectionStrategyImageURLs
- (id)initWithSelectedImageURL:(NSURL *)selectedImageURL updatedImageURL:(NSURL *)updatedImageURL {
    return %orig(newCoverURL(selectedImageURL), newCoverURL(updatedImageURL));
}
%end

%ctor {
    if (ytlBool(@"shortsOnlyMode") && (ytlBool(@"removeShorts") || ytlBool(@"reExplore"))) {
        ytlSetBool(NO, @"removeShorts");
        ytlSetBool(NO, @"reExplore");
    }

    if (!ytlBool(@"advancedMode") && !ytlBool(@"advancedModeReminder")) {
        ytlSetBool(YES, @"advancedModeReminder");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{
                ytlSetBool(YES, @"advancedMode");
            }
            actionTitle:LOC(@"Yes")
            cancelTitle:LOC(@"No")];
            alertView.title = @"YTLite";
            alertView.subtitle = [NSString stringWithFormat:LOC(@"AdvancedModeReminder"), @"YTLite", LOC(@"Version"), LOC(@"Advanced")];
            [alertView show];
        });
    }
}
