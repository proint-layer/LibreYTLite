// ELMTrace.x — ELM reverse-engineering: DYNAMIC VALIDATION harness
// ============================================================================
// The *static* map of YouTube's ELM (Element) UI framework lives in ELM_RE.md. That map
// was reconstructed from a header dump (interfaces only, no method bodies), so every claim
// about data-flow — most importantly "the ⋯ kebab AND the long-press context menu both
// funnel through YTMenuController → YTActionSheetController" — is INFERRED, not observed.
//
// This file is how we OBSERVE it. It installs passthrough tracers on the choke points the
// static map identifies, so a few taps on a device turn the inferred call-graph into a real
// one. Nothing here injects, mutates, or changes behaviour: every hook logs and calls %orig.
// This is the "dynamic validation" half of the RE suite — not a feature.
//
//   Build:  make clean package DEBUG=0 FINALPACKAGE=1 ELM_RE=1
//   Read:   log stream --predicate 'eventMessage CONTAINS "[YTLELM]"'  (or Console.app)
//   Not shipped: this file lives in re/ and is compiled ONLY when ELM_RE=1 (see Makefile) —
//   a normal `make package` never includes it. The #if below is belt-and-suspenders.
//   Command traces too:  add ADDITIONAL_CFLAGS="-DYTL_POST_DEBUG" (YTLite.x's ELMController/
//   responder tracers).
//
// TYPES MATTER (this is why the suite exists): a Logos hook with the wrong return type
// returns garbage to real callers; an `id`-typed hook on a `const void *` C++ argument
// crashes the moment you touch it. Every signature below was taken from `ipsw class-dump`,
// not guessed. In ELM the command object crosses the C++/ObjC boundary as `const void *`
// on ELMController/ELMCommandResolver — those are logged BY PRESENCE ONLY, never
// dereferenced. The one place the command is a real ObjC `id` is YTELMDispatcher.

#if defined(YTL_ELM_RE)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

// Forward decls give `self`/args a pointer type for the hooks. All three are genuine
// NSObject subclasses (per class-dump), and we only ever send -class/-description to the
// *object* arguments — never to the C++ pointers.
@interface YTMenuController : NSObject @end
@interface ELMTouchCommandPropertiesHandler : NSObject @end
@interface YTELMDispatcher : NSObject @end

static void elmtLog(NSString *s) { os_log(OS_LOG_DEFAULT, "[YTLELM] %{public}@", s); }
#define ELMT(...) elmtLog([NSString stringWithFormat:__VA_ARGS__])

// Class name + a one-line, newline-flattened, trimmed -description. For the proto-backed
// menu renderer / command objects this exposes the concrete type and payload. ARGUMENT MUST
// BE AN OBJC id — never pass a `const void *` C++ pointer here.
static NSString *elmtStr(id o) {
    if (!o) return @"nil";
    NSString *d = [o respondsToSelector:@selector(description)] ? [o description] : @"";
    d = [d stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (d.length > 220) d = [[d substringToIndex:220] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@ | %@", [o class], d];
}

%group gELMTrace

// -- MENU CONSTRUCTION -------------------------------------------------------
// The static map's central claim: both the ⋯ kebab and the cell long-press resolve into
// YTMenuController, which turns a (mutable) YTIMenuRenderer into a UIKit YTActionSheetController.
// If these fire on a kebab tap AND on a channel-Videos long-press, the claim holds and
// YTIMenuRenderer mutation becomes a viable injection point. If a menu appears with NO line
// here, it does NOT go through YTMenuController — a decisive negative result worth knowing.
//
// showMenu* has 7 overloads; we trace 2. The `%@` payload is the YTIMenuRenderer proto — it
// lists the menu's items, so you can see exactly what the sheet is built from.
//
// NOTE: -actionsForRenderers: was traced here originally to confirm the menu funnel. That's
// now settled AND the shipped queue feature hooks that same selector in YTLite.x
// (ytlInjectQueueActions), so tracing it here too would be a duplicate-symbol clash — removed.
%hook YTMenuController
- (void)showMenuWithMenuRenderer:(id)renderer fromView:(id)view entry:(id)entry firstResponder:(id)responder {
    ELMT(@"MENU.show(4)  %@", elmtStr(renderer)); %orig;
}
- (void)showMenuWithMenuRenderer:(id)renderer fromView:(id)view entry:(id)entry dismissalBlock:(id)block addCancelAction:(BOOL)cancel shouldLogItems:(BOOL)logItems firstResponder:(id)responder completion:(id)completion {
    ELMT(@"MENU.show(8)  %@", elmtStr(renderer)); %orig;
}
%end

// -- TOUCH → COMMAND BRIDGE --------------------------------------------------
// Which gesture fires on which surface, and that command resolution runs. `command` here is
// a `const void *` C++ Command pointer (verified via class-dump) — logged by presence via the
// recognizer class ONLY; dereferencing it as an object would crash.
%hook ELMTouchCommandPropertiesHandler
- (void)handleTap          { ELMT(@"TOUCH.tap"); %orig; }
- (void)handleLongPress    { ELMT(@"TOUCH.longPress"); %orig; }
- (void)handleContextClick { ELMT(@"TOUCH.contextClick"); %orig; }
- (void)resolveCommand:(const void *)command forRecognizer:(id)recognizer {
    ELMT(@"TOUCH.resolve  rec=%@", [recognizer class]); %orig;
}
%end

// -- COMMAND DISPATCH (ObjC bridge) ------------------------------------------
// The ELM→YTResponder bridge. Unlike ELMController/ELMCommandResolver (C++ `const void *`),
// here `command` is a real ObjC id — the one command object we can safely introspect. Shows
// the concrete command a tap / menu-item selection actually produces.
%hook YTELMDispatcher
- (void)dispatchCommand:(id)command fromSender:(id)sender completion:(id)completion {
    ELMT(@"DISPATCH  cmd=%@  sender=%@", elmtStr(command), [sender class]); %orig;
}
%end

%end // group gELMTrace

%ctor { %init(gELMTrace); elmtLog(@"ELM RE tracer loaded"); }

#endif // YTL_ELM_RE
