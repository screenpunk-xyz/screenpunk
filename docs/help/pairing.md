# Pair a device

1. Open Screenpunk on the iPhone or iPad. It shows **Ready to pair** and
   asks for Local Network permission. Allow it, and keep Screenpunk in the
   foreground; it only advertises itself while it is on screen.
2. On the Mac, open Screenpunk. Under **Add Device** in the sidebar, the
   phone appears by name within a few seconds (or press the refresh arrow).
   Press **Pair** next to it. If it never appears, open **Add by address**
   and enter the host and port from the device's **Ready to pair** screen,
   then press **Pair**.
3. Both screens show the same six-digit matching code. Confirm on both,
   and only if the codes match exactly. If they differ, cancel on both and
   start again.
4. Choose portrait or landscape on the Mac. The device follows that choice.

Codes expire after two minutes. Five wrong confirmations pause pairing;
start over. A device belongs to one Mac at a time; a second Mac cannot pair
with it until it is unlinked. To unlink, hold two fingers on the device's
screen for ten seconds, then tap **Unlink** (`get_help` topic `unlink`).

Pairing authorizes one Mac to manage the device. It does not grant access
to any service. Connections are approved separately in Screenpunk on the
Mac; agents can propose them but cannot approve them.

If discovery never shows the device: both machines need Local Network
permission, must be on the same network, and the network must allow
Bonjour (mDNS). Manual host and port works without Bonjour. Screenpunk
never scans your network.
