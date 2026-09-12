# Offline ring

A ring around the edge of the screen with an **Offline** tab at the bottom
means a required connection of the current dashboard failed, or its data is
older than the dashboard allows. The dashboard keeps showing its last
successful data.

- Screenpunk draws the ring, not the dashboard. Dashboard code cannot show
  or hide it.
- It does not block taps or scrolling.
- It disappears when every required connection is healthy again.
- The Mac being off, asleep, or away never causes it. A deployed dashboard
  does not need the Mac.

Optional connections never show the ring; their widgets explain their own
problems. A dashboard with no connections never shows the ring.

If the ring stays on: check the network the device is using, the upstream
service (for example Home Assistant), and whether a token was revoked or
expired. Fix the connection in Screenpunk on the Mac and deploy again if
its settings changed.

The ring is not a reason to reset the device. To remove the dashboard
entirely, hold two fingers on the screen for ten seconds, then tap
**Unlink**.
