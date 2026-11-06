# Request checklist (from the latest prompt)

Status legend: [ ] todo · [x] done · [~] partial / explore-only

## 0. Ground rules
- [x] R1. Cloud sync is MANDATORY and fixed FIRST, before anything else
- [x] R2. Check GitHub: was I working from an older code base? Diagnose and fix sync
- [x] R3. No user data lost anywhere (migration-safe, no deletions)
- [x] R4. Tests must NEVER upload to the live server — keep all test data local
- [x] R5. Don't invent categories/data that don't exist — stats only reflect existing data
- [x] R6. Finish by: commit, push, build the signed IPA into ~/Downloads

## 1. Map / live drive
- [x] M1. Restore the blue dotted "most efficient route" guide line (regressed)
- [x] M2. Zoom out further; zoom computed from route length (still readable for upcoming turns)
- [x] M3. ETA and delay status verified working properly

## 2. Apple Watch
- [x] W1. Watch app can stop a drive
- [x] W2. Shows basic info: ETA and delay status
- [x] W3. Shows which turn to take next (next-turn instruction)
- [ ] W4. (low priority) small map on the watch
- [x] W5. Watch Live Activity / Smart Stack: richer data

## 3. iPhone Live Activity
- [x] L1. Richer data on the iPhone Live Activity (lock screen + Dynamic Island)

## 4. Trips page
- [x] T1. Intuitively change a trip's destination and schedule from the Trips page
- [x] T2. Add a diversion to a trip AFTER it's completed, from the trip's page
- [x] T3. Connection time visible: layered BETWEEN two trips (scheduled/linked) that share a stop, < 3h — Flighty style layover
- [x] T4. Connection time also shown on the Trips list page

## 5. Siri / Shortcuts
- [x] S1. Expose shortcut destinations (App Intents) so Apple Shortcuts / Siri can start drives to saved places

## 6. Stats (Flighty-style past-flights presentation)
- [x] ST1. Richer statistics page, built only from existing data
- [x] ST2. Pick a "trip type" (route, e.g. Home -> Shop) and see all trips from that start to that destination
- [x] ST3. Per-route average / maximum / minimum duration, etc.

## 7. Gas fill-up page
- [x] G1. Remember last fill-up's vehicle + payer as defaults (no hardcoding); price & amount stay blank
- [x] G2. Tap a past fill-up to see details (like tapping a trip)

## 8. Explore only (do NOT build)
- [x] C1. Calendar integration: events with locations -> auto-schedule drives from last arrival to event, and event to next scheduled drive's start. Write up the possibility.

## Notes on what "done" means
- W4 (small map on the watch) is intentionally NOT done — marked low priority; needs route geometry streamed to the watch.
- C1 is explore-only: see CALENDAR_INTEGRATION_EXPLORATION.md (nothing built).
- R6: commit + push + IPA performed as the final step.
- T2 "diversion after the fact" is stored on the phone only: the backend has no column for it (offer: add `divertedFromName` to the web schema).
