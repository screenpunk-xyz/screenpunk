# Calendar agenda

An offline screen package that displays the next seven days from calendars the
owner selects in the device's native Google Calendar settings. Requires the
Calendar-capable iOS build and configured Google OAuth client; the Mac preview
cannot use the device's account.

Deploy this directory with the normal Screenpunk package workflow. Open the
device's Settings → Google Calendar, connect accounts, and select calendars for
Calendar agenda. Read-only event requests go directly from the device to Google.

After editing the example, regenerate its SDK copy and manifest from the repo root:

```sh
node --import ./sdk/node_modules/tsx/dist/loader.mjs examples/google-calendar/build.mts
```

The view displays at most 40 events, sorted by start time. Calendar strings are
inserted with textContent. Error states clear previously rendered events.
