# Apple Watch app + Live Activity — target setup

All the Swift source is written and the **iPhone side is fully wired and building**. The two pieces
below each need a new Xcode target (target creation is a GUI action, so it isn't done for you — but
it's a few clicks each, and no code changes are required).

## What's already done (in the app target, building green)
- `Driving app/Models/DriveActivityAttributes.swift` — shared Live Activity data model.
- `Driving app/Models/LiveActivityController.swift` — starts/updates/ends the activity.
- `LiveTrackingView` starts the activity on drive start, updates it as you move, ends it on finish.
- `Info.plist` → `NSSupportsLiveActivities = YES`.
- `Driving app/Models/PhoneWatchConnectivity.swift` — mirrors drives + stats to the watch and
  forwards the watch's "start" request. Activated in `ContentView`; the Dashboard broadcasts on
  change; a watch start request opens live tracking for that scheduled drive.

## 1. Live Activity — Widget Extension target
1. File ▸ New ▸ Target… ▸ **Widget Extension**. Name it `DriveActivity`. Uncheck "Include
   Configuration App Intent"; **check "Include Live Activity"**.
2. Delete the template files Xcode generates, and instead add the files already written here:
   `DriveActivityExtension/DriveActivityBundle.swift`, `DriveActivityLiveActivity.swift`,
   `Info.plist`.
3. Add `Driving app/Models/DriveActivityAttributes.swift` to the **extension's** target membership
   (File Inspector ▸ Target Membership ▸ check `DriveActivity`) so both sides share the type.
4. Build & run. Start a drive → the Live Activity (progress bar + scheduled-vs-estimated arrival)
   appears on the Lock Screen and Dynamic Island.

## 2. Apple Watch companion — watchOS App target
1. File ▸ New ▸ Target… ▸ **watchOS ▸ App**. Name it `DriveWatch`. SwiftUI / no complications
   needed. Xcode will pair it to the iOS app automatically.
2. Delete the template `ContentView`/`App` files and add the files already written here:
   `DriveWatch Watch App/DriveWatchApp.swift`, `WatchConnectivityManager.swift`,
   `WatchContentView.swift`.
3. Both targets already use WatchConnectivity — no capability toggles required.
4. Build & run the watch scheme (with the phone app running once to push the first sync). The watch
   shows upcoming drives (tap to start one on the phone) and a stats summary.

## Optional: share data via an App Group (only if you later want the widget/watch to read SwiftData directly)
Not required for the above — the phone pushes everything over WatchConnectivity and updates the
Live Activity directly. If you later want richer offline data on the watch, add an App Group
capability to all three targets and point the SwiftData `ModelContainer` at the shared container.
