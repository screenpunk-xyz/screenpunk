# Google Calendar on independent devices

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../../docs/screen-authoring-persistence.md).


Implemented for the iOS/iPadOS device settings and native screen bridge. No
Screenpunk account, backend, proxy, or running Mac is required. Each device
completes Google's installed-app authorization in ASWebAuthenticationSession,
using PKCE S256 and a validated one-time state/callback. Tokens, account metadata,
and per-screen calendar selections remain in ThisDeviceOnly Keychain storage.
The Mac authoring preview does not authorize a device's Google account.

## Google project structure

Create these under the Screenpunk Google Cloud organization:

- Screenpunk Device Integrations — Development
- Screenpunk Device Integrations — Production

These are durable Google application registrations, not hosted Screenpunk
services. Both use the same implementation; builds supply the appropriate public
client ID and callback scheme. Google's OAuth policy requires separate testing
and production projects. A production project can support future Google
connectors, including Gmail and Drive, with separately requested permissions and
additional verification where required. Each supported platform needs the
appropriate OAuth client registration. Other providers require registrations
with those providers; they do not use Google's OAuth client IDs.

Google's authorization/revocation boundary spans a project. Revoking the Google
grant may invalidate this user's tokens on other devices and future connectors
in that project. “Remove” here deletes the local account and all its screen
selections without calling Google's project-wide revocation endpoint. Settings
also links to Google's account connections page for explicit global revocation.

## Console setup (repeat for each environment)

1. Create the Google Cloud project under the Screenpunk organization.
2. Enable Google Calendar API.
3. Configure Google Auth Platform Branding: app name, support email, developer
   contact, website, privacy policy, and authorized domains.
4. Select External audience for a customer-facing application. Add named test
   users to the development project's Testing audience. Testing Calendar grants
   and refresh tokens normally expire after seven days.
5. Declare `openid`, `https://www.googleapis.com/auth/userinfo.email`,
   `https://www.googleapis.com/auth/userinfo.profile`, and:
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
   - `https://www.googleapis.com/auth/calendar.events.readonly`
The Dev project is `edge-goog-00`; Prod is `edge-goog-01`. The supplied Dev
   iOS client is configured in `apps/ios/project.yml` for Debug builds. Release
   keeps empty values until the production client is supplied. For a development
   device test built with Release optimizations, pass both Dev settings explicitly
   on that local build command; do not distribute it as the production app.
6. Create an **iOS** OAuth client for bundle ID `xyz.screenpunk.ios`. No native
   client secret is required. Do not select Web or TVs/Limited Input devices.
7. Supply build settings (an xcconfig or xcodebuild arguments):
   ```text
   SCREENPUNK_GOOGLE_CALENDAR_CLIENT_ID = YOUR_ID.apps.googleusercontent.com
   SCREENPUNK_GOOGLE_CALENDAR_REVERSED_CLIENT_ID = com.googleusercontent.apps.YOUR_ID
   ```
   Info.plist consumes these for the client ID and registered URL scheme. The
   redirect URI is `com.googleusercontent.apps.YOUR_ID:/oauth2redirect`.
   An unconfigured build shows a disabled connect action; it never substitutes
   another environment's client ID. Client IDs are public configuration.
8. For production, complete branding/domain and sensitive-scope verification,
   including accurate data-use disclosures, scope justification, and a video
   demonstrating consent, calendar selection, and display. Organization approval
   alone does not approve this OAuth application.

Do not add Gmail or Drive permissions to Calendar consent. The email/OpenID/profile
permissions identify accounts and provide optional display names and profile-picture
URLs for family views; they do not read Gmail.
Google's limited-input device-code flow does not list Calendar scopes as allowed.
Sign in directly on the device with its system browser; leave Guided Access
while completing setup if it prevents browser authorization.

## Device setup

Install a screen declaring `googleCalendar` (legacy alias `google-calendar` is
also accepted). Open device Settings → Google Calendar. Connect one or more
accounts and choose calendars independently for each installed screen. An account
stays manageable if no remaining screen uses Calendar. Removing an account clears
its selections everywhere on this device. Device Disconnect erases local Calendar
storage. Refresh calendars updates the picker and drops selections no longer
returned by Google. Reconnect through the account button when Google access expires.

## Screen contract

Manifest connection:

```json
{"alias":"googleCalendar","required":true,"operations":[{"name":"events","kind":"http"}]}
```

Read the selected calendars (no calendar IDs, tokens, headers or URLs accepted):

```js
const { value, stale } = await screenpunk.connections.request(
  'googleCalendar', 'events', {
    timeMin: new Date().toISOString(),
    timeMax: new Date(Date.now() + 7 * 86400000).toISOString()
  }
);
// value = { events: [...], accounts: [...], calendars: [...], fetchedAt: ISO8601String }
```

Only the active top-level local package with a matching manifest declaration may
call this operation. Native owner selections limit the calendars read. Maximum
window: 31 days; 20 selected calendars per screen; at most 20 API pages and 10,000
results per request. Exceeding bounds fails rather than silently truncating.
Results are grouped by selected calendar; screens sort them for presentation.
Events contain accountID, calendarID, id, summary, start, end, location, status.
They exclude descriptions, attendees, conference links and credentials.
`accounts` contains only accounts with calendars selected for this screen, with
`accountID`, `displayName` (email fallback), and optional HTTPS `pictureURL`.
These profiles identify connected Google accounts, not every owner/participant
of a shared calendar. Missing pictures must fall back to initials or an icon.
Profile metadata is captured during connection/reconnection. Existing stored
accounts without profile fields remain usable. Avatar rendering through the
native image boundary remains follow-up work; do not relax the screen's network
isolation to load arbitrary image URLs.

`calendars` contains every calendar selected for this screen, including calendars
with zero events in the requested window. Each entry has exactly `accountID`,
`calendarID`, and `displayName` (the saved calendar title, including Google's
summaryOverride when present). Use the pair `(accountID, calendarID)` as its key;
the same shared calendar can be selected through different accounts. Use this
array for calendar rows/filters instead of inferring calendars from events or
account profiles. Do not substitute an account's name for a calendar's title.
Unselected calendars and selections belonging only to other screens are excluded.
Calendar metadata follows native selection order and appears on both fresh-cache
and transient stale responses; existing event error/invalidation rules still
apply. Refresh calendars in native settings to update saved titles. Older app
builds may omit `calendars`; authors should tolerate the missing field during
mixed-version upgrades.

Recurring events are expanded by Google for the requested window. Cancelled events
are omitted. Date-only all-day values and exclusive end dates are preserved;
render them as calendar dates, not UTC instants. Timed values retain offsets and
Google's timeZone fields. Missing titles display as “Busy”. Screen authors must
render event strings as text, not HTML.

Poll about once a minute while active. Identical requests reuse a 60-second
in-memory cache. A transient network/server failure may return that same window
stale for up to 15 minutes; label it accordingly. Permission errors, reconnect
errors, selection changes, removal, and unlink do not use stale fallback. No event
cache persists to disk. Rate/server errors impose a bounded retry delay.
Clear displayed data on connection errors. As with other private screen data,
authorized screen JavaScript can retain values already delivered to it.

Error codes: `notConfigured`, `authorization`, `reconnect`, `permission`,
`invalidRequest`, `tooLarge`, `unavailable`, `rateLimited`; transport errors from
the bridge use `device_offline`. Subscription operations are unsupported.

Example: `examples/google-calendar` (agenda for the next seven days).

## Acceptance before release

Use a real configured iOS build and test account to verify consent, callback,
multiple accounts, independent selections, app restart and refresh, denied scopes,
revocation/reconnect, shared calendars, recurring exceptions, all-day/DST display,
offline recovery, removing an account and device Disconnect. Verify no tokens in
packages, MCP results, diagnostics, or screenshots. Test the native settings on an
actual device and confirm Google production verification separately.

## References

- [Google OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [Installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth)
- [Testing audience](https://support.google.com/cloud/answer/15549945)
- [Verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)

## Local validation — September 28, 2026

- Twelve focused Swift tests passed: PKCE/callback validation, form escaping,
  selection isolation/persistence, request bounds, event pagination/field filtering,
  refresh-token persistence, revoked/partial grants, calendar removal, secure
  erasure, unlink during refresh, and rate-limit backoff.
- Unsigned iOS Simulator build passed with the existing iOS 16 deployment target.
- Example manifest and file inventory validated with the SDK package validator.
- No live Google authorization, physical-device UI acceptance, or production
  verification performed. The Dev iOS client is now configured in Debug builds; live authorization remains unverified.

### Selected-calendar inventory follow-up

The 2026092803+ native response adds `calendars` as documented above. Seventeen
Calendar tests pass, including a seven-selected/five-with-events fixture, exact
field filtering, same-ID calendars across accounts, selection privacy, fresh
cache reuse, transient stale metadata, selection removal, and permission errors
clearing stale cache. Tests use synthetic accounts and do not read private data.
The combined interactive-map build is 2026092804; deployment status is recorded
in [apple-maps-validation.md](apple-maps-validation.md).
