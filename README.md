# lightsession-ios

Session recording for iOS, native Swift, no dependencies.

| Package | Swift Package Manager | CocoaPods | Minimum iOS |
| --- | --- | --- | --- |
| `LightSession` | [![SPM](https://img.shields.io/github/v/tag/LightSession/lightsession-ios?style=for-the-badge&label=SPM&color=green)](https://github.com/LightSession/lightsession-ios/releases) | [![CocoaPods](https://img.shields.io/cocoapods/v/LightSession?style=for-the-badge&color=green)](https://cocoapods.org/pods/LightSession) | 15.0 |

```swift
// Swift Package Manager
.package(url: "https://github.com/LightSession/lightsession-ios.git", from: "0.3.0")
```

```ruby
# CocoaPods
pod 'LightSession', '~> 0.2'
```

Unlike the Android SDK, whose artefact lives on Maven Central, both of these resolve by cloning
**this repository** — so neither works while it is private. The version badge above reads from the
tags, which is the same thing Swift Package Manager resolves against.

Three things, in the order they were built:

- **The screen map** — what an app's screens are and how people move between them. Each screen arrives as
  a wireframe and a real screenshot; the moves arrive as edges in the same graph the Android and React
  Native SDKs write into.
- **Interactions** — taps and swipes, which is what a touch heatmap is drawn from.
- **Session replay** — the screen on a timer, masked before it leaves the device.

## Integrating it

A UIKit app needs one call:

```swift
import LightSession

func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    LightSession.start(
        .init(
            apiKey: "…",
            apiURL: "https://api.example.com",
            // A second, genuinely different service. Without it the screen map still works and there is
            // no replay and no heatmap — the log says so once rather than leaving you waiting.
            ingestURL: "https://ingest.example.com"
        )
    )
    return true
}
```

That is all. `UIViewController.viewDidAppear` is hooked once, so every screen the app already has is
mapped without a line of code in it.

A SwiftUI app needs two, because the platform genuinely cannot name a SwiftUI screen — its screens are
values in a `body`, and the controllers `NavigationStack` builds under them are private types whose names
change between releases. Reading those is how an integration rots.

```swift
LightSession.start(.init(apiKey: "…", apiURL: "…", screensReportedByHost: true))

// then, on each screen:
HomeView().lightSessionScreen("Home")

// and on a part of a screen that is a place of its own:
.sheet(isPresented: $showing) { FiltersView().lightSessionSubScreen("Filters") }
```

An app that mixes the two — UIKit screens with SwiftUI inside some of them — needs nothing special. Leave
the flag off and name the SwiftUI screens; the SDK works out that a hosting controller whose contents the
app has named is a container rather than a screen.

### Recording the network the app made

Off by default, and the only setting here that is. Everything else describes what the SDK does to
itself; this one puts our code near the app's own traffic, so nobody gets it without asking twice —
once for the flag, once for the client.

```swift
LightSession.start(.init(apiKey: "…", apiURL: "…", captureNetwork: true))

// and on the app's own client — this is the whole integration:
let session = URLSession(
    configuration: .default,
    delegate: LightSessionURLSessionDelegate(),
    delegateQueue: nil
)
```

`data(for:)` and the other async calls keep working; a session with a delegate is often assumed to be
the old completion-handler world and is not.

An app whose session already has a delegate keeps it and adds one line:

```swift
func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
) {
    LightSession.record(task, metrics: metrics)
}
```

Anything that is not `URLSession` — Alamofire's `EventMonitor`, a hand-written client — calls the
primitive the other two are built on:

```swift
LightSession.recordRequest(
    method: "POST", url: url, statusCode: 201, durationMillis: 118,
    requestBytes: 348, responseBytes: 1204, error: nil
)
```

**There is no global hook, deliberately.** `URLProtocol` is the obvious way to capture everything with
no integration at all, and what it actually does is re-issue every request the app makes through our
code. Swizzling means being right about a private implementation on every future OS. Neither is worth
a chart, so the customer's own client is where this attaches — visible, removable, theirs.

**What is captured:** method, host, the path with its dynamic segments collapsed, status, duration,
request and response body sizes, a one-word failure class, and the screen that was waiting.

**What is never captured, on any setting:** request bodies, response bodies, headers, and the query
string. Not redacted — there is no field to hold them, so no later edit adds one by loosening a
filter. Collapsing happens *on the device*: `/v1/orders/{id}/items` is what leaves, never
`/v1/orders/84321/items`, because a token that reaches a server has already left the building.

**Sampling** is `networkSampleRate`, and the unit is the session rather than the request:

```swift
LightSession.start(.init(apiKey: "…", apiURL: "…", captureNetwork: true, networkSampleRate: 0.1))
```

A coin per request at a tenth would turn a screen that fires six calls at once into one recorded
call, and a reader would conclude the screen makes one request — a lie about the app's structure
rather than about its volume. So a session is recorded whole or not at all. **Failures are recorded
regardless**, marked as standing for no traffic, so a rare one can still be opened and watched
without moving any rate or percentile. Default `1.0`: sampling makes every number an estimate, and
the dashboard says so by showing the sample size beside the count.

Recording follows `stopRecording()`, and calls are batched with everything else rather than flushed
one at a time — a chatty screen would otherwise make the SDK the network problem it exists to measure.

## What was measured

A UIKit app with five shapes in it, driven end to end on an iPhone 17 simulator against a local backend:

| Question | Result |
| --- | --- |
| Are UIKit screens named and mapped, with no code in them? | **Yes** — four screens, `kind = UIKIT` |
| Is a SwiftUI screen mapped from the app's own name? | **Yes** — `SwiftUIHome`, `kind = SWIFTUI` |
| Does every screen get a wireframe? | **Yes** — one skeleton each |
| Does every screen get a real screenshot? | **Yes** — one each, 63–126 KB |
| Is `maskText` applied before the image leaves the device? | **Yes** — verified by looking: a form holding a name, an email and a phone number arrived with every one of them covered |
| Are the moves between screens recorded? | **Yes** — seven flows, including the pops back |
| Is the wireframe legible? | **Yes** — fields, labels, the button and the nav title all distinguishable |
| Do replay frames arrive? | **Yes** — 168 frames in one session, in batches of 24 |
| Are unchanged frames deduplicated? | **Yes** — a 24-frame batch carried 9 real JPEGs and 15 four-byte signals, and the server's manifest agrees |
| Are replay frames masked and shrunk? | **Yes** — verified by pulling one out of object storage and looking: 402×874 (a third of 1206×2622), 9.9 KB, every label covered |
| Are screen changes on the session's timeline? | **Yes** — eight `navigation` rows with the right `from`/`to` and order |
| Do taps and swipes reach the heatmap? | **Yes** for the payload and the whole server path, driven through the SDK's own code: `TAP` and `SWIPE` rows with `x_px`/`y_px` and a five-point path, rendered as a heatmap over the iOS screenshot. **Not yet** for the touch capture itself — see below |

The one thing not verified is whether the gesture recognizer sees real touches, because this machine has no
way to generate one: `simctl` has no tap command, and `cliclick`, `idb` and Quartz are all absent while
AppleScript is blocked on accessibility permission. Everything downstream of the touch is measured; the touch
itself needs a finger.

## How it works, and the three things that are load-bearing

**Classification is by superclass, never by class name.** `UILabel` is text, `UITextField` is an input,
`WKWebView` is a web view — and so is every subclass of them, from a design system, from a third party,
from SwiftUI's own internals. This is the property that made React Native work on Android with no
React-specific code at all, and it is the same property here.

**A screen is captured when it stops changing, not when it appears.** `viewDidAppear` fires before
asynchronous content lands, and SwiftUI's `onAppear` fires before layout has happened at all. A
`CADisplayLink` samples how many *drawing* views the window has and settles once that number holds steady
for three frames. The stop condition counts content rather than views because a window is never empty: it
always has a root view and a safe-area container.

**The decisions are pure functions with tests.** `planScreenSource`, `actionForObservedController` and
`SkeletonBuilder` take plain values and return plain values, so `swift test` walks them on macOS in about
five milliseconds — no simulator. That is why the package declares macOS as well as iOS, with everything
UIKit-shaped behind `#if canImport(UIKit)`.

```
swift test                       # 80 tests, on macOS, no simulator
Example/build.sh                 # builds the sample .app for the simulator
```

**Touches are observed, never intercepted.** Android reads `MotionEvent` by wrapping `Window.Callback`, and
the delegation to the host is the last line of the method — so a bug there both crashes the app and swallows
the touch. iOS's equivalent is `UIWindow.sendEvent(_:)` and it is deliberately not swizzled. Instead a
`UIGestureRecognizer` subclass that never recognises anything observes from `.possible`, with
`cancelsTouchesInView = false`. The failure mode of a bug in here is a missing interaction rather than a
frozen app, which is the right way round.

**Recording and uploading are separate jobs.** A recorder writes a batch to disk and is finished; a drain
reads files, uploads oldest first, and deletes each one only once the server has taken it. So whoever produced
the data does not have to survive long enough for a request to finish — which is what used to be wrong: a
failed upload was logged and dropped, and a person who used the app underground lost everything they did
there. Breadcrumbs drain before frames, because a tap is a few hundred bytes and is the only record it
happened, while a frame is tens of kilobytes and the one beside it looks almost identical.

Verified by breaking it on purpose: the ingest service was suspended, the app was driven through four screens,
and three batches queued on disk with exactly **one** refused attempt — the drain stops on the first failure
rather than hammering a dead connection. The service was resumed, and within one 5-second tick the queue was
empty and all six navigation events were in ClickHouse.

**One session, two streams.** `SessionCoordinator` owns the id because `session_id` is the only thing on the
wire that says a tap and a frame belong to the same visit. It was extracted the moment replay arrived: two
owners is two sessions, and the product then shows a replay with no interactions beside a session with no
video.

## Three bugs this found, none of which reading the code would have caught

**A hosting controller was reported as a screen.** The first real run produced a node called
`SwiftUIHostViewController` and an edge to it from `SwiftUIHome` — a navigation the user never made, to a
container rather than a place. `onAppear` and `viewDidAppear` fire in an order neither side promises, so
the fix is a short grace: a hosting controller is reported only if the app has not named its contents by
the time it expires.

**The fix for that failed, for the reason the code warns about elsewhere.** It detected hosting
controllers by testing the class name for `UIHostingController`, and apps subclass that routinely — the
sample's own `SwiftUIHostViewController` contains no trace of the word. The ancestry is walked now, which
is the rule the view classifier already followed and this code had quietly broken.

**A widget's own chrome was drawn on top of the widget.** A `UITextField` puts a rounded-rect background
view inside itself; that view is a plain `UIView` with a colour, so it was drawn as an `UNKNOWN` in the
app's grey — exactly covering the orange input beneath. The form's wireframe was three grey slabs where
three fields were, and a text label beside them was green, so nothing in the picture said which was which.
Worth recording *how* it was found: the render was fetched and looked at. The PNG before and after the
first attempted fix differed by six bytes out of sixty-eight thousand, so file size would have said
nothing either way.

## Known gaps

- **The spool lives in `Library/Caches`,** which the system may evict under storage pressure. That is the
  deliberate trade: `Documents` and `Application Support` are backed up, and a user's iCloud backup is no
  place for telemetry about them. Losing a queued batch beats the OS deciding the app is the problem.
- **An idle screen is recorded but not uploaded eagerly.** A batch goes out on a count of *real* frames, so
  three minutes of an untouched screen produce one upload rather than seven. This was measured the wrong way
  round first: an app left open for 38 minutes sent 96 batches, 95 holding nothing but four-byte repeat
  signals, long after the server had finalised the session. The frames are still recorded and still uploaded —
  they travel with whatever happens next, or when the app leaves.
- **Nothing avoids the render on an unchanged screen.** Android watches draw callbacks and skips the capture
  entirely; iOS has no equivalent public hook, so a frame is rendered and *then* compared. The upload and the
  storage are deduplicated — a repeat is four bytes — but one `drawHierarchy` per second on an idle screen is
  paid regardless. Skipping it by comparing layout geometry instead would miss a label whose text changed in
  place, which is a worse trade.
- **Multi-touch is one finger.** A pinch records whichever touch the set yields first. A heatmap of two-finger
  gestures is not what the feature is for, and a path that jumps between fingers is worse than one finger's.
- **A tab's screen is named after its own controller**, so two tabs holding the same controller class collapse
  into one node. Android models tabs as `Parent › Tab`; iOS does not yet.
- **`UIAlertController` is filtered out** rather than reported as `Parent › Alert`. The sub-screen mechanism
  exists — `setSubScreen(_:)` — and nothing calls it from UIKit yet.
- **The status bar is not in the capture.** It lives in a system window, and only the app's own window is
  rendered.
- **The cache cannot learn that the server lost something.** Delete a project's data server-side and every
  existing install keeps saying "already sent". Shared with the Android SDK, where it was watched happening: a
  full navigation of a wiped project produced a perfect log and an empty database. It cost three measurements
  in one day before it was written down. Today the only cure is a version bump, because the app version is
  part of every cache key.
- **No crash or error capture** — and worth saying plainly that Android has none either, so this is a gap in
  the product rather than a gap in the port.
- **No CocoaPods podspec.** SwiftPM only.

## Layout

- `Sources/LightSession/` — `LightSession.swift` is the whole public API; `Mapper/` holds the tracker, the
  settle detector, the wireframe builder and the pure decisions; `Network/` holds the payloads and the
  one `URLSession` that sends them; `ApiCalls/` holds the capture of the *app's* traffic, which is a
  different subject from ours and is why it is a different directory.
- `Tests/LightSessionTests/` — the pure decisions, walked exhaustively where the space is small enough to
  walk.
- `Example/` — a UIKit app with SwiftUI inside it, built into a simulator `.app` by `build.sh` without an
  Xcode project. It takes `-demoRoutes pushed,back,form` so it can be driven from a script; the iOS
  simulator has no `uiautomator`, and a driver that taps coordinates stops testing anything the day the
  layout changes.
