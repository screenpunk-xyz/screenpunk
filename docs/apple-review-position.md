# Apple review position (draft)

This is a planning position, not a promise of App Store acceptance.

Screenpunk's iOS app is a thin native wrapper. It loads a user-authored,
locally bundled HTML/CSS/JavaScript dashboard in WKWebView. The native host
owns credentials, approved HTTP/WebSocket operations, package validation,
and recovery UI. JavaScript cannot access raw tokens or unrestricted
networking.

Relevant guideline families to re-read before any submission (current at
review time, not at this bootstrap):

- 2.5.2 — downloaded code / executable code
- 4.7 — mini apps, mini games, streaming games, chatbots, plug-ins, and
  native-bridge conditions

Position to defend:

1. Dashboards are user-authored local packages transferred over a paired LAN
   channel, not a Screenpunk-hosted store of third-party mini-apps.
2. The web view cannot fetch remote scripts or open arbitrary network
   connections; the native bridge validates origin, grant, and size.
3. There is no in-app purchase, account, or cloud runtime for the alpha.
4. Preview/MCP run on the user's Mac, not on the phone.

Open feasibility questions that can force a product change:

- Hidden WKWebView snapshot on the selected macOS CI image and a real Mac
  (probe exists; no Linux stand-in PNG).
- Isolation on iOS 16 versus current iOS (policy + fixtures exist; WK
  enforcement still needs a device/simulator run).
- Whether Apple treats LAN-deployed user HTML as downloaded code.

Do not claim review will succeed. Update this document after the Milestone 0
spikes produce evidence.
