# Calendar integration — exploration (nothing built yet)

**Idea:** read calendar events that have a location, and automatically propose scheduled drives:
1. **To the event** — from where your previous drive ended (or where you'll be) to the event's location, timed to arrive before it starts.
2. **From the event** — from the event's location to wherever your next scheduled drive departs from.

## What iOS gives us

| Piece | API | Notes |
|---|---|---|
| Read events | **EventKit** (`EKEventStore`) | iOS 17+ has *write-only* and *full* access tiers; we need **full access** (`requestFullAccessToEvents`). Needs `NSCalendarsFullAccessUsageDescription` in Info.plist. Read-only use, so no data is changed in the user's calendar. |
| Event location | `EKEvent.structuredLocation` (title + `CLLocation`) or free-text `location` | `structuredLocation` often has coordinates already (events created from Maps/Siri/invites). Free-text locations need geocoding with `MKLocalSearch` — the same address search the app already uses. |
| Travel time | `MKDirections` ETA with `departureDate` | Already used by Predict a Route / scheduled drives. Traffic is forecast for the departure time, so "leave by" is realistic. |
| Alerts | `UNUserNotificationCenter` | "Leave in 10 min for Choir practice" local notification, plus a Live Activity if desired. |
| Background refresh | `BGAppRefreshTask` / `EKEventStoreChanged` notification | Recompute when the calendar changes. |

## Proposed behaviour

1. **Opt-in** screen in Settings → Calendar: choose which calendars to watch (e.g. exclude Birthdays, Holidays), a default "arrive N minutes early" buffer, and a vehicle + payer to use.
2. Each day, look ahead (e.g. 7 days) for events that have a usable location and aren't all-day.
3. Build an ordered timeline of **anchors** = events + the user's existing scheduled drives, sorted by time. Between each consecutive pair, propose a **proposed drive** when the places differ (> ~250 m):
   - *Origin* = location of the previous anchor (event location, or the previous drive's destination; for the first of the day, Home / the last recorded trip's end).
   - *Destination* = the next anchor's location.
   - *Arrival target* = next event start − buffer; *departure* = target − MapKit travel time (with traffic for that time).
4. Show proposals as **"Suggested drives"** on the Drive tab (never auto-created silently). One tap **Accept** creates a normal `ScheduledDrive` (so grading, ETA, Watch, Live Activity all work unchanged); **Dismiss** remembers the dismissal per event.
5. Re-evaluate when events move: if an accepted drive came from an event that changed time/location, offer to update it. Remember the link with `EKEvent.eventIdentifier` + `calendarItemExternalIdentifier` (stored on the `ScheduledDrive`).
6. **Connections:** if an event's location is where the previous drive ended and the gap is < 3 h, the existing connection (layover) UI applies — "1h 10m connection at Church" — because the proposed "from the event" drive starts exactly where the earlier trip ended.

## Data-model impact

- `ScheduledDrive`: add optional `sourceEventID: String?` and `sourceCalendarID: String?` (lightweight-migration safe — optional with default nil).
- New small table `DismissedSuggestion(eventID, date)` — or a `UserDefaults` set; it is local-only.
- Backend: `ScheduledDrive` has no column for the event link. Either keep the link local-only (simple, recommended first) or add an optional `sourceEventId` column to the Prisma schema.

## Edge cases to design for

- **Event with no location / virtual meeting URL** → ignore (don't geocode "Zoom").
- **Location is just a venue name** ("Costco") → ambiguous; geocode near the user's region and show the match for confirmation before accepting.
- **Overlapping events / double-booked** → propose for the earliest, flag the conflict.
- **Time zones / floating events** → resolve in the event's own time zone.
- **Recurring events** → create/offer one proposal per occurrence inside the look-ahead window; accepting a "repeat" can map onto the existing `repeatRule`.
- **Privacy** → events never leave the phone; only the resulting scheduled drives sync to the cloud (like today). Never upload event titles/notes.
- **Permission denied** → feature stays hidden; no nagging.

## Suggested build order (when you want it)

1. EventKit permission + calendar picker + read events with locations (read-only, behind a Settings switch).
2. Geocode + MapKit travel-time engine reusing `RouteMatcher.multiLegRoute(through:departure:)`.
3. "Suggested drives" list with Accept / Dismiss → creates `ScheduledDrive`.
4. Change detection + local notifications ("Leave in 10 min").
5. (Optional) Siri/Shortcut: "What's my next drive?" via the App Intents added alongside this document.

## Open questions for you

- Should accepting a suggestion auto-pick the vehicle/payer you used last for that route?
- Is a 7-day look-ahead right, or only today + tomorrow?
- Do you want suggestions for *every* event with a location, or only for calendars you pick?
