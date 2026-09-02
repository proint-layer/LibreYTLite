#import <Foundation/Foundation.h>

// Audio download manager (v1). Self-contained: NO playback/media hooks. Given a videoID it
// makes its OWN InnerTube /player request impersonating the ANDROID_VR (Oculus/Quest) client
// — which is NOT in this account's SABR/Onesie bucket and so returns classic ready-to-fetch
// per-format URLs (no signatureCipher, no nsig, no PO token) — picks the best AAC/m4a audio
// format, range-GET downloads the whole track to a temp file, and hands it to a "Save to Files"
// share sheet. See re/ (itprobe.py/dltest.py) for the feasibility proof and the download-manager-re
// memo for why this sidestep works where the app's own pipeline (and the paid app) cannot.
@interface YTLDownloadManager : NSObject
+ (void)downloadAudioForVideoID:(NSString *)videoID;
@end
