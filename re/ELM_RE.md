# ELM reverse-engineering — map + dynamic validation

**ELM (Element)** is YouTube's declarative, server-driven UI framework. Feed cells, the ⋯
"kebab" overflow menu, cell long-press context menus, buttons, and most modern surfaces are
ELM-rendered rather than built from hand-wired UIKit. That is why they resist the injection
techniques that work elsewhere: there is no `UIContextMenuInteraction` to grab, no
`YTActionSheet` we constructed, no per-button setter to swizzle. This document maps ELM well
enough to find where we *can* reach in, and pairs with **`ELMTrace.x`**, a dynamic-validation
harness that confirms the map against a running device before anything is built on top of it.

> **Read this first — the map is INFERRED.** The class/method map below was reconstructed
> from an Objective-C **header dump** (`ipsw macho info --objc` / `ipsw class-dump` of
> YouTube 21.25.5) — interfaces, ivars, and method *signatures*, but **no method bodies**.
> Every statement about *data-flow between* methods ("the kebab funnels through
> YTMenuController", "handleLongPress calls resolveCommand:") is inferred from names, types,
> and ivars, **not observed**. Do not build a feature on an inferred path. Validate it with
> `ELMTrace.x` first (§5). This is the whole reason the suite exists: the queue-on-channel-
> pages saga was caused by hooking an inferred/guessed path without confirming it fires.

---

## 1. The three layers

ELM has three concentric layers. Injection difficulty rises as you go inward.

```
  server proto ──▶  ELEMENT ──▶ NODE ──▶ VIEW          (§2 pipeline)
                       │
                       ├── gesture ──▶ COMMAND ──▶ dispatch   (§3 commands)
                       │
                       └── ⋯ / long-press ──▶ MENU ──▶ UIKit sheet   (§4 menus)  ◀── injection target
```

The pleasant surprise from the static map: although the *outer* skin is all ELM, the **menu
layer (§4) resolves back into a plain UIKit `YTActionSheetController`** with a mutable item
model. So the practical reach-in point is much shallower than "re-implement ELM." **Pending
validation (§5),** injecting a menu item looks *easy*, not hard.

---

## 2. Element → Node → View pipeline

There is **no `ELMNode` base class.** ELM nodes are AsyncDisplayKit/Texture `ASDisplayNode`
subclasses conforming to `<ELMDisplayNode>`; each carries an `ELMElement` and a controller.

```
YTIElementRenderer (GPBMessage)        the on-the-wire owner; .elementData = serialized bytes
        │  -initWithElementData: / -initWithElement:
        ▼
ELMElement (NSObject)                  wraps C++ youtube::elements::Element + arena
        │  built by ELMElementFactory -createElement:
        ▼
ELMComponent / ELMNodeController       the id<ELMController> "hub" — materializes element→node
        │  -locked_materialize / -locked_createModel (builds the *Model objects)
        ▼
ELMNodeFactory  (singleton)            maps int nodeType → Class<ELMDisplayNode>
        │  -nodeWithElement:materializationContext:  /  -classForElement:...
        ▼  (+ per-class swap: +[ELMCellNode replacementClassForElement:materializationContext:])
NODE  ASDisplayNode<ELMDisplayNode>    ELMCellNode:ASCellNode, ELMContainerNode, ELMImageNode,
        │                              ELMTextNode …; concrete: YTVideoNode:ELMCellNode, YTCommentNode
        ▼  ASDisplayNode.view (lazy) → _ASDisplayView
VIEW                                   _ASDisplayView.asyncdisplaykit_node (weak back-ref) →
                                       node.element / node.controller  (round-trip from a UIView)
```

- **Who owns the raw entry data:** `ELMElement` (C++ element tree); one level up, `YTIElementRenderer.elementData` (serialized bytes — YTLite already scans these for the community-post gallery).
- **Live view → element round-trip:** `_ASDisplayView.asyncdisplaykit_node` → `-element` / `-controller` (`<ELMDisplayNode>` protocol).
- **Feed-cell handoff:** `+[ELMCellNode nodeBlockForEntry:responder:]` — the "entry" carries the `YTIElementRenderer` before any node exists. Best per-cell server-payload read.
- **Swap what a node renders app-wide:** `-[ELMNodeFactory registerNodeClass:forTypeExtension:]` / `+[ELMCellNode replacementClassForElement:materializationContext:]`.
- `managesGestureHandling` is per node (ELMCellNode / ELMContainerNode / ELMImageNode / ELMTextNode) — relevant to gesture ownership. **Home and channel-Videos cells are the same `YTVideoNode : ELMCellNode` hierarchy**; the difference that broke the queue long-press was never the cell class — it is the menu/command context around it.

---

## 3. Command / action dispatch

Two-tier: an ELM-native tier (proto commands run in-process) and a bridge tier (server
`YTICommand`s routed to native VCs).

- **Per-controller entry:** `-[<ELMController> handleCommand:]` / `handleCommand:additionalSenderState:`, implemented by `ELMComponent`, `ELMNodeController`, `ELMReference`, `ELMViewHostController` (4 classes — *not* one global choke).
- **Global funnel (ObjC singleton):** `ELMCommandResolver` (`+sharedInstance`) → `resolveCommand:…withContext:sender:recognizer:` (3 variants). Sees every command with/without an ObjC handler.
- **Routed by proto extension number:** `ELMCommandHandlerResolver -handleCommand:context:completion:`.
- **Command payload:** `ELMPBCommand : GPBMessage` — a wrapper; the concrete command rides as a **GPB extension** (extension number → handler). 30 `ELMPB*Command` types; ~78 classes implement `-executeWithCommandContext:handler:` (per-class, directly swizzleable): `ELMPBUrlCommand`, `ELMPBShowActionSheetCommand`, `ELMPBShowBottomSheetCommand`, `ELMPBUpdateActionSheetCommand`, `ELMPBInlinePlaybackCommand`, plus many `YTI*Command`. Some (e.g. `ELMPBCopyToClipboardCommand`, `ELMPBParallelCommand`/`SerialCommand`) have **no** ObjC handler — they run via the C++ fusion path and have no per-class ObjC seam.
- **Touch → command:** `ELMTouchCommandPropertiesHandler` (`<UIGestureRecognizerDelegate>`) owns one recognizer per gesture; target methods `handleTap` / `handleLongPress` / `handleContextClick` / … resolve via `resolveCommand:forRecognizer:` to the element's bound command. `ELMContextClickGestureRecognizer` is the right-click/trackpad path.
- **ELM → native bridge:** `YTELMDispatcher -dispatchCommand:fromSender:completion:` / `-handleCommand:sender:completionBlock:` — crosses ELM commands into the `YTResponder` chain. **This is the one place the command is a real ObjC object** (see §6). Downstream native router: `YTCommandRouter handleCommand:entry:fromView:sender:`.
- **Mutable models (where an action could be rewritten):** base `ELMButtonModel`/`ELMCommandRunModel` expose `onTap`/`onLongPress` read-only off the proto; the **`ELMMutableButtonModel` / `ELMMutableCommandRunModel`** subclasses have `setOnTap:` / `setOnLongPress:` / `setEnabled:`.

---

## 4. Menu construction — the injection target

**Both** the ⋯ kebab **and** the cell long-press (inferred) resolve into the same place, and
it is **UIKit**, not ELM:

```
⋯ kebab  ─┐                                     openPopupAction → YTIMenuPopupRenderer
long-press ┤─▶ ELMTouchCommandPropertiesHandler ─▶ (command resolves to a menu renderer OR
           │     handleLongPress/handleContextClick    an ELMPBShowActionSheetCommand)
           ▼
   YTMenuController
     -showMenuWithMenuRenderer:fromView:entry:…firstResponder:   (7 overloads, all → void)
        │  builds items via:
        ▼
     -actionsForRenderers:fromView:entry:…firstResponder:  → NSArray of actions
        │
        ▼
   YTActionSheetController / YTDefaultSheetController   (UIKit sheet; has -addAction:)
```

- **The menu model is MUTABLE:** `YTIMenuRenderer` has `-addMenuServiceItem:`, `-addMenuNavigationItem:`, `-insertMenuNavigationItem:atIndex:`.
- **Build one item:** `+[YTIMenuServiceItemRenderer menuServiceItemWithServiceEndpoint:text:iconType:]` — exactly the fields an "Add to queue" row needs.
- **Or append to the built sheet:** `-[YTActionSheetController addAction:]` with `+[YTActionSheetAction actionWithTitle:iconImage:style:accessibilityIdentifier:handler:]` — a **custom handler block**, so we sidestep the server-locked native queue command entirely.
- **Confirmed NOT UIKit context-menu:** no YouTube/ELM class implements `contextMenuConfigurationForItemAtIndexPath:` etc. (only AsyncDisplayKit's `ASCommonCollectionDelegate`). So there is no `UIContextMenuInteraction` delegate to hook for feed cells — the long-press funnels back through the ELM command → `YTMenuController` path above.
- `ELMPBOverflowMenuItemState` is **per-item dynamic state** (isToggled/isAvailable/…), **not** the item list — not an injection surface.
- Pure-ELM sheets (`ELMPBShowActionSheetCommand` → `YTElementsActionSheetController`) carry element trees (`listOptionArray` of `ELMPBElement`) — heavy to construct — but `YTElementsActionSheetController` **subclasses** `YTActionSheetController`, so it still inherits `-addAction:`.

---

## 5. Dynamic validation — how to confirm the map (do this before building anything)

`ELMTrace.x` installs passthrough tracers on the §3–§4 choke points. It changes no behaviour;
it only answers "does this path actually fire, and with what?"

```sh
# build the RE variant (already produced as YouTube_YTLite_ELMRE.ipa). ELM_RE=1 is the only
# switch — it pulls re/ELMTrace.x into the build and defines YTL_ELM_RE (see Makefile). A plain
# `make package` compiles none of this.
make clean package DEBUG=0 FINALPACKAGE=1 ELM_RE=1
# add ADDITIONAL_CFLAGS="-DYTL_POST_DEBUG" too for YTLite.x's ELMController/responder path traces

# on the device, stream the tracer
log stream --predicate 'eventMessage CONTAINS "[YTLELM]"'   # or Console.app, filter [YTLELM]
```

Trigger these and read the log:

| Gesture | What to look for | What it proves |
|---|---|---|
| Tap ⋯ on a **home** feed video | `MENU.show(…)` and/or `MENU.actions items=N` | kebab → `YTMenuController` (the easy injection path is real) |
| **Long-press** a **home** feed video | `TOUCH.longPress` → `TOUCH.resolve` → `MENU.actions` | home long-press uses the same menu funnel |
| **Long-press** a **channel → Videos** grid cell | same chain? or `TOUCH.*` with **no** `MENU.*`? | **the key test** — does the channel grid reach `YTMenuController`, or does its menu come from elsewhere? |
| Select any menu item | `DISPATCH cmd=<ELMPB…/YTICommand …>` | the concrete command a menu row fires (the real ObjC command object) |

**Reading the results**
- `MENU.actions items=N` firing on all three surfaces ⇒ the "everything funnels through
  `YTMenuController`" claim holds; injecting via `YTIMenuRenderer` mutation or `actionsForRenderers:`
  append (§7) is viable **and covers channel Videos** — the surface the queue couldn't reach.
- Channel-grid long-press showing `TOUCH.*` but **no** `MENU.*` ⇒ decisive negative: its menu
  is built by a different path; re-RE from the `DISPATCH` line's command type. **Better to
  learn this from one log line than from another shipped guess.**
- The `MENU.show %@` payload is the `YTIMenuRenderer`'s proto description — it lists the menu's
  items, so you can see exactly what you'd be appending to.

### Validation result — CONFIRMED on device (YouTube 21.25.5)

The inferred map held on every surface. Traced with `-DYTL_ELM_RE`:

| Surface | Gesture | Observed chain | `MENU.actions` |
|---|---|---|---|
| Home feed | tap ⋯ | `TOUCH.tap` → `DISPATCH YTICommand ext 98150882 (YTIMenuEndpoint)` → `MENU.show(8) YTIMenuRenderer` | **items=8** |
| Home feed | long-press | `TOUCH.longPress` → `TOUCH.resolve (UILongPressGestureRecognizer)` → `DISPATCH …MenuEndpoint` → `MENU.show(8)` | ✓ |
| **Channel → Videos** | tap ⋯ | `TOUCH.tap` → `DISPATCH …MenuEndpoint` → `MENU.show(8)` | **items=5** |
| **Channel → Videos** | **long-press** | `TOUCH.longPress` → `TOUCH.resolve` → `DISPATCH …MenuEndpoint` → `MENU.show(8)` | **items=5** |

Conclusions (these are now observed, not inferred):
1. **Both the ⋯ kebab and the long-press, on home AND channel-Videos, funnel through
   `-[YTMenuController showMenuWithMenuRenderer:…]` with a live, mutable `YTIMenuRenderer`.**
   Injection candidate #1 (§7) is viable on every surface — **including the channel-Videos grid
   the queue long-press could never win.** The "ELM wall" was a misdiagnosis: the menu is a
   UIKit-bridged, mutable renderer, not an opaque ELM render.
2. The menu-opening command is a **`YTICommand` (a real `id` at `YTELMDispatcher`)** carrying
   extension **98150882 = `YTIMenuEndpoint`**; navigation taps carry **48687626 = `YTIBrowseEndpoint`**.
   The `const void *` discipline (§6) paid off — the payload was only safely readable here.
3. The live `YTIMenuRenderer` already contains a **"Play next in queue"**
   `menu_conditional_service_item_renderer` as its first item on every surface. Worth a separate
   look (is that the server-locked native queue, or something tappable now?) — but orthogonal to
   injecting our own item.
4. Menu-item *selection* (step D) did not surface a distinct `YTELMDispatcher` line, so menu rows
   likely dispatch through `YTCommandRouter`, not the ELM dispatcher — irrelevant to injection,
   which happens at renderer-build time.

---

## 6. The C++/ObjC boundary — the gotcha that makes naive hooks crash

The ELM command object is a C++ `youtube::elements::Command`. It crosses into ObjC method
signatures as a **`const void *`**, **not** an `id`. Verified via `ipsw class-dump`:

| Method | `command` arg type | Safe to `-description`? |
|---|---|---|
| `-[ELMController handleCommand:]` | `const void *` | **NO** — C++ pointer |
| `-[ELMCommandResolver resolveCommand:…]` | `const void *` | **NO** |
| `-[ELMTouchCommandPropertiesHandler resolveCommand:forRecognizer:]` | `const void *` | **NO** |
| `-[YTELMDispatcher dispatchCommand:fromSender:completion:]` | **`id`** | **YES** — real ObjC object |

Hooking any of the top three with an `(id)command` signature and then messaging `command`
(e.g. `[command description]`) **crashes** — you are sending ObjC messages to a raw C++
pointer. `ELMTrace.x` traces the top three **by presence only** (recognizer/sender class), and
introspects the command payload **only** at `YTELMDispatcher`, where it is a genuine `id`.

> Historical note: YTLite.x's older `%hook ELMController` trace declared `(id)command` and
> called a `-description`-based labeler on it — a latent crash-on-first-command under
> `-DYTL_POST_DEBUG`. Corrected to `const void *` + presence-only logging when this suite was
> built. Also verify return types: all `showMenuWithMenuRenderer:…` are `void`; both
> `actionsForRenderers:…` return `id` (an array). A wrong return type returns garbage to real
> callers.

---

## 7. Injection candidates — DOCUMENTED, NOT IMPLEMENTED

**None of these are built.** They are the shortlist to try **after** §5 confirms the path.
Ranked easiest/safest first.

1. **`-[YTMenuController showMenuWithMenuRenderer:…]`** — mutate the incoming `YTIMenuRenderer`
   (`addMenuServiceItem:` / `insertMenuNavigationItem:atIndex:`) **before** `%orig`;
   `actionsForRenderers:` then renders your row automatically. One choke point; covers kebab +
   long-press **if §5 confirms both route here**. *Strongest candidate.*
2. **`-[YTMenuController actionsForRenderers:…]`** — append a `YTActionSheetAction`
   (`+actionWithTitle:iconImage:style:accessibilityIdentifier:handler:`, custom handler block)
   to the returned array. Bypasses the renderer model entirely.
3. **`-[YTActionSheetController addAction:]`** — for sheets YTLite already builds itself.
4. **`+[YTElementsActionSheetController showActionSheetWithCommand:…]`** — pure-ELM sheets;
   inherits `addAction:`, but native rows are element-views so a plain action may look
   inconsistent. Medium.
5. **`-[<ELMController> handleCommand:additionalSenderState:]`** / `ELMMutable*Model setOnLongPress:`
   / `-[ELMNodeFactory registerNodeClass:…]` — deeper behaviour/render overrides. Hard; only if
   the menu path is a dead end.

**Do not skip §5.** Candidate #1 is only "easy" if the tracer shows `MENU.*` firing on the
target surface. If it doesn't, #1 silently does nothing — the exact failure mode this suite
was built to end.

---

## 8. Verified selectors (present in 21.25.5) & source

All confirmed present via the dump; types via `ipsw class-dump`.

```
# menu (injection target)
-[YTMenuController showMenuWithMenuRenderer:fromView:entry:firstResponder:]            → void   (×7 overloads)
-[YTMenuController actionsForRenderers:fromView:entry:firstResponder:]                 → id (NSArray)
-[YTIMenuRenderer addMenuServiceItem:] / addMenuNavigationItem: / insertMenuNavigationItem:atIndex:
+[YTIMenuServiceItemRenderer menuServiceItemWithServiceEndpoint:text:iconType:]
-[YTActionSheetController addAction:]   +[YTActionSheetAction actionWithTitle:iconImage:style:accessibilityIdentifier:handler:]
+[YTElementsActionSheetController showActionSheetWithCommand:commandContext:handler:]
# commands
-[ELMCommandResolver resolveCommand:withContext:sender:recognizer:]                    (command = const void *)
-[ELMCommandHandlerResolver handleCommand:context:completion:]
-[YTELMDispatcher dispatchCommand:fromSender:completion:]                              (command = id ✓)
-[<cmd> executeWithCommandContext:handler:]                                           (~78 per-class impls)
# touch
-[ELMTouchCommandPropertiesHandler handleTap|handleLongPress|handleContextClick]       → void
-[ELMTouchCommandPropertiesHandler resolveCommand:forRecognizer:]                       (command = const void *)
# pipeline
+[ELMCellNode nodeBlockForEntry:responder:]   +[ELMCellNode replacementClassForElement:materializationContext:]
-[ELMNodeFactory registerNodeClass:forTypeExtension:] / -nodeWithElement:materializationContext:
```

- **Harness:** `re/ELMTrace.x` — opt-in only: `make package ELM_RE=1`. Excluded from every normal build.
- **Regenerate the dump:** `ipsw macho info --objc Payload/YouTube.app/YouTube` (selectors);
  `ipsw class-dump <MachO> --class '^Name$'` (typed signatures).
- **Pipeline discipline:** AGENTS.md §8 (RE the selector *and its types* → instrument → confirm
  it fires → only then build).
