Here's the catalogue. Availability figures are pulled from Apple's documentation JSON (`developer.apple.com/tutorials/data/...`), so they're the authoritative `@available` lines rather than prose.

## 1. `contentTransition` — animating content *within* a view

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.contentTransition(.numericText(value:))` | Digits roll vertically like an odometer/fuel gauge; counts up or down based on the delta. The canonical "premium" one. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/numerictext(value:)) |
| `.contentTransition(.numericText(countsDown:))` | Same, but you force the direction instead of deriving it from a value. | **14.0+** | [docs](https://developer.apple.com/documentation/SwiftUI/ContentTransition/numericText(countsDown:)) |
| `.contentTransition(.interpolate)` | Morphs vector paths between the old and new content — shapes/symbols deform into each other rather than cross-fade. | **13.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/interpolate) |
| `.contentTransition(.opacity)` | Plain cross-fade. The safe fallback; reads as "correct" but not special. | **13.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/opacity) |
| `.contentTransition(.identity)` | Hard cut, no animation. Use to *suppress* an inherited transition. | **13.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/identity) |
| `.contentTransition(.symbolEffect)` | Applies the symbol's default transition effect to any SF Symbol in the changed subtree. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/symboleffect) |
| `.contentTransition(.symbolEffect(.replace))` | Old symbol scales/fades out as the new one scales in — the play/pause button feel. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/contenttransition/symboleffect(_:options:)) |
| `.symbolEffect(.replace.downUp)` (also `.upUp`, `.offUp`) | Directional replace: outgoing symbol exits downward, incoming enters from below. Feels deliberate rather than generic. | **14.0+** | [ReplaceSymbolEffect](https://developer.apple.com/documentation/symbols/replacesymboleffect) |
| `.symbolEffect(.replace.magic(fallback:))` | Magic Replace — shared layers (badges, slashes, wifi bars) persist and animate *through* the swap instead of restarting. Best-in-class. | **15.0+** | [docs](https://developer.apple.com/documentation/symbols/replacesymboleffect/magic(fallback:)) |

## 2. Symbol effects (`.symbolEffect`)

All applied via [`.symbolEffect(_:options:value:)`](https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:value:)); reference session is [WWDC23 "Animate symbols in your app"](https://developer.apple.com/videos/play/wwdc2023/10258/).

| API | What it looks like | macOS |
|---|---|---|
| [`.bounce`](https://developer.apple.com/documentation/symbols/bouncesymboleffect) | One-shot squash-and-pop, layer-by-layer. Best discrete "it worked" acknowledgement. | **14.0+** |
| [`.pulse`](https://developer.apple.com/documentation/symbols/pulsesymboleffect) | Opacity breathing on the "pulsable" layers; indefinite. Ongoing/recording state. | **14.0+** |
| [`.variableColor`](https://developer.apple.com/documentation/symbols/variablecolorsymboleffect) | Layers illuminate in sequence (wifi bars, cell signal). `.iterative`, `.cumulative`, `.reversing` variants. | **14.0+** |
| [`.wiggle`](https://developer.apple.com/documentation/symbols/wigglesymboleffect) | Directional shake — attention-grabbing, e.g. a rejected input. | **15.0+** |
| [`.breathe`](https://developer.apple.com/documentation/symbols/breathesymboleffect) | Slow smooth scale in/out. The most "premium" idle indicator; much calmer than `.pulse`. | **15.0+** |
| [`.rotate`](https://developer.apple.com/documentation/symbols/rotatesymboleffect) | Layers spin around their designed anchor points (fan blades, gear teeth). | **15.0+** |
| [`.scale`](https://developer.apple.com/documentation/symbols/scalesymboleffect) | Indefinite scale up/down that holds while active — a toggled emphasis state. | **14.0+** |
| [`.appear`](https://developer.apple.com/documentation/symbols/appearsymboleffect) / [`.disappear`](https://developer.apple.com/documentation/symbols/disappearsymboleffect) | Symbol scales in/out from its own layers while keeping its layout slot. | **14.0+** |
| [`.drawOn`](https://developer.apple.com/documentation/symbols/drawonsymboleffect) / [`.drawOff`](https://developer.apple.com/documentation/symbols/drawoffsymboleffect) | **2025 headline.** Strokes trace on/off like handwriting, following calligraphic direction. `.byLayer` / `.individually` / `.wholeSymbol` control stagger. Transition effects — pair with `.transition(.symbolEffect(.drawOn))`. | **26.0+** |

Related macOS 26 knobs that make the above look better: [`.symbolColorRenderingMode(_:)`](https://developer.apple.com/documentation/swiftui/view/symbolcolorrenderingmode(_:)) and [`.symbolVariableValueMode(_:)`](https://developer.apple.com/documentation/swiftui/view/symbolvariablevaluemode(_:)), both macOS 26.0+. See [WWDC25 "What's new in SF Symbols 7"](https://developer.apple.com/videos/play/wwdc2025/337/).

## 3. Matched geometry & navigation transitions

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.matchedGeometryEffect(id:in:)` | A view appears to fly and resize from one position to another across a state change. The workhorse hero transition. | **11.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)) |
| `.matchedTransitionSource(id:in:)` | Marks the source view for a navigation/sheet zoom. | **15.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/matchedtransitionsource(id:in:)) |
| `.navigationTransition(.zoom(sourceID:in:))` | Destination inflates out of the tapped cell, interruptible and interactively dismissable. | ⚠️ **not on macOS** — `.navigationTransition(_:)` is macOS 15.0+, but `.zoom` is iOS 18 / iPadOS 18 / tvOS 18 / visionOS 2 / watchOS 11 only. On macOS use `matchedGeometryEffect`. | [zoom](https://developer.apple.com/documentation/SwiftUI/NavigationTransition/zoom(sourceID:in:)), [WWDC24 10145](https://developer.apple.com/videos/play/wwdc2024/10145/) |

## 4. Multi-step animation drivers

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.phaseAnimator(_:content:animation:)` | Cycles a view through a sequence of discrete states with a per-phase animation — e.g. lift → tilt → settle. Cheapest way to get a choreographed multi-beat effect. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/phaseanimator(_:content:animation:)) |
| `.keyframeAnimator(initialValue:trigger:...)` | Independent tracks (scale, rotation, offset, opacity) each on their own timeline with cubic/spring/linear/move keyframes. Disney-style anticipation-and-overshoot. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/keyframeanimator(initialvalue:trigger:content:keyframes:)) |

Both from [WWDC23 "Wind your way through advanced animations in SwiftUI"](https://developer.apple.com/videos/play/wwdc2023/10157/).

## 5. Spring presets

All introduced iOS 17 / **macOS 14.0+**, from [WWDC23 "Explore SwiftUI animation"](https://developer.apple.com/videos/play/wwdc2023/10156/). (Note: Apple's doc pages for these show the *type's* `macOS 10.15` line, not the member's.)

| API | What it looks like |
|---|---|
| [`.spring(duration:bounce:)`](https://developer.apple.com/documentation/swiftui/animation/spring(duration:bounce:blendduration:)) | Perceptual spring: `duration` is the settling time you actually feel, `bounce` 0…1. Velocity-preserving when retargeted mid-flight — the reason gestures feel expensive. |
| [`.bouncy`](https://developer.apple.com/documentation/swiftui/animation/bouncy) | ~0.5s, bounce 0.3. Playful overshoot. |
| [`.snappy`](https://developer.apple.com/documentation/swiftui/animation/snappy) | ~0.5s, bounce 0.15. Slight overshoot; the default "feels good" choice for UI chrome. |
| [`.smooth`](https://developer.apple.com/documentation/swiftui/animation/smooth) | ~0.5s, no bounce. Calm and authoritative; right for large surfaces. |

## 6. Scroll-driven effects

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.scrollTransition(_:axis:transition:)` | Per-item effects keyed off `ScrollTransitionPhase` (`.topLeading`/`.identity`/`.bottomTrailing`) — cards that scale, fade, blur, or rotate as they enter/leave the viewport. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/scrolltransition(_:axis:transition:)) |
| `.visualEffect { content, proxy in ... }` | Geometry-reading effects with no layout invalidation — parallax, depth, distance-from-center scaling. The building block under most premium scroll UIs. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/visualeffect(_:)) |
| `.scrollEdgeEffectStyle(_:for:)` | macOS 26 progressive blur/fade where content slides under toolbars. `.soft` (gradual dissolve) vs `.hard` (defined line). | **26.0+** | [docs](https://developer.apple.com/documentation/SwiftUI/View/scrollEdgeEffectStyle(_:for:)), [`.soft`](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle/soft) |
| `.scrollEdgeEffectHidden(_:for:)` | Opts a specific edge out of the above. | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)) |

## 7. Custom text rendering

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `TextRenderer` protocol | Draw a `Text` glyph-by-glyph / run-by-run yourself: per-character offsets, blur, rotation, color, shader passes. | **14.0+** | [docs](https://developer.apple.com/documentation/swiftui/textrenderer) |
| `.textRenderer(_:)` | Attaches your renderer to a Text hierarchy. | **15.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/textrenderer(_:)) |
| Typewriter / staggered-reveal pattern | Conform the renderer to `Animatable` and animate `elapsedTime`; each glyph gets its own `elementDuration` window, so characters spring/blur in one at a time. Not a built-in preset — the WWDC24 sample is the reference implementation. | 15.0+ | [WWDC24 "Create custom visual effects with SwiftUI"](https://developer.apple.com/videos/play/wwdc2024/10151/) · [sample gist](https://gist.github.com/coughski/9d15f9b08c877a82b0f92a7364a1516c) · [fatbobman writeup](https://fatbobman.com/en/posts/creating-stunning-dynamic-text-effects-with-textrender/) |

## 8. Liquid Glass (macOS 26)

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.glassEffect(_:in:)` | Refractive, specular glass material behind arbitrary content; capsule by default, any shape via `in:`. | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) |
| `.glassEffect(.regular.interactive())` | Adds pressure/hover response — the glass bends and brightens under the pointer. | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/glass/interactive(_:)) |
| `GlassEffectContainer` | Merges sibling glass shapes into one lens so they blend/gooify when near, and so glass never samples glass. Required for morphing. | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/glasseffectcontainer/) |
| `.glassEffectID(_:in:)` | The star: two glass elements with matching IDs in a namespace **liquid-morph into each other** on insertion/removal — stretching, splitting, and re-coalescing like mercury. | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)) |
| `.glassEffectTransition(_:)` | Controls that morph (`.materialize`, `.matchedGeometry`, `.identity`). | **26.0+** | [docs](https://developer.apple.com/documentation/swiftui/glasseffecttransition) |

Reference: [WWDC25 "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323/) and [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) · working sample: [Landmarks](https://developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass).

## 9. View transitions

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `.transition(.blurReplace)` | Outgoing view blurs and scales out while the incoming blurs in — the single highest premium-per-character transition in SwiftUI. `.blurReplace(.downUp)` adds direction. | **14.0+** | [BlurReplaceTransition](https://developer.apple.com/documentation/swiftui/blurreplacetransition) |
| `.transition(.push(from: .bottom))` | New content shoves the old out along an edge, both moving together. | **13.0+** | [docs](https://developer.apple.com/documentation/swiftui/anytransition/push(from:)) |
| `.transition(.move(edge:).combined(with: .opacity))` | Slide + fade. Combine with `.scale(scale:anchor:)` for the classic "grow from the button" feel. | 10.15+ | [docs](https://developer.apple.com/documentation/swiftui/view/transition(_:)) |
| `.transition(.symbolEffect(.drawOn))` | Symbol strokes itself into existence on insert. | **26.0+** | [SymbolEffectTransition](https://developer.apple.com/documentation/swiftui/symboleffecttransition) |

## 10. Gradients & surfaces

| API | What it looks like | macOS | Source |
|---|---|---|---|
| `MeshGradient(width:height:points:colors:)` | Bézier-interpolated color surface from a control-point grid. Animate the interior points with `TimelineView(.animation)` + `sin`/`cos` for a slow lava-lamp drift; keep edge points pinned so the frame stays stable. | **15.0+** | [docs](https://developer.apple.com/documentation/swiftui/meshgradient) · [nilcoalescing animation recipe](https://nilcoalescing.com/blog/MeshGradientsInSwiftUI/) · [Donny Wals](https://www.donnywals.com/getting-started-with-mesh-gradients-on-ios-18/) |
| `.backgroundExtensionEffect()` | Mirrors and blurs the view's own edges outward into the safe area — artwork bleeds under a floating sidebar or toolbar instead of hard-clipping. | **26.0+** | [docs](https://developer.apple.com/documentation/SwiftUI/View/backgroundExtensionEffect()) · [Landmarks sample](https://developer.apple.com/documentation/SwiftUI/Landmarks-Applying-a-background-extension-effect) |

## Two corrections to the brief

- **`.hoverEffect` is not available on macOS.** [`HoverEffect`](https://developer.apple.com/documentation/swiftui/hovereffect) is iOS 13.4 / tvOS 16 / visionOS 1, and the richer `.hoverEffect(_:in:isEnabled:)` is visionOS 2 only. The macOS equivalents are [`.pointerStyle(_:)`](https://developer.apple.com/documentation/swiftui/view/pointerstyle(_:)) (macOS 15.0+) plus `.onHover { }` driving your own animation, or `.glassEffect(.regular.interactive())` on macOS 26.
- **`.navigationTransition(.zoom)` is not available on macOS** either, despite the `navigationTransition(_:)` modifier itself being macOS 15+. Use `matchedGeometryEffect` for hero transitions on the Mac.

If you want the highest ratio of perceived polish to effort on macOS 26 specifically, the shortlist is: `.numericText`, `.blurReplace`, `.symbolEffect(.replace.magic)`, `.breathe`, `GlassEffectContainer` + `glassEffectID` morphing, and `.scrollTransition` with `.visualEffect`.

Sources: [ContentTransition](https://developer.apple.com/documentation/swiftui/contenttransition) · [ReplaceSymbolEffect](https://developer.apple.com/documentation/symbols/replacesymboleffect) · [WWDC23 10258](https://developer.apple.com/videos/play/wwdc2023/10258/) · [WWDC25 337](https://developer.apple.com/videos/play/wwdc2025/337/) · [WWDC23 10157](https://developer.apple.com/videos/play/wwdc2023/10157/) · [WWDC23 10156](https://developer.apple.com/videos/play/wwdc2023/10156/) · [WWDC24 10151](https://developer.apple.com/videos/play/wwdc2024/10151/) · [WWDC24 10145](https://developer.apple.com/videos/play/wwdc2024/10145/) · [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) · [SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui) · [createwithswift: draw animations](https://www.createwithswift.com/implementing-draw-animations-for-sf-symbols-in-swiftui/) · [nilcoalescing: animating SF Symbols](https://nilcoalescing.com/blog/AnimatingSFSymbolsInSwiftUI/) · [createwithswift: TextRenderer](https://www.createwithswift.com/text-effects-using-textrenderer-in-swiftui/)
