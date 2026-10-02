# Native Cloud user identity integration

## Accepted contract

This client slice targets Cloud commit `37c83d4560541e64c2dd5df8cd9bd085086d8b8c` (Cloud PR 29). The canonical sources are `docs/native-sign-in.md`, `docs/api/openapi.json`, and the fifteen sanitized responses in `docs/api/native-sign-in-fixtures.json` at that commit.

The supported operations are explicit recent sign-in (`POST /v1/native/sign-in`), workspace discovery (`GET /v1/native/accounts`), and location discovery (`GET /v1/native/accounts/:accountId/locations`). These establish a human account context, not device management authority. Empty results must remain empty; a continuation cursor must be followed even after an empty page. Initial workspace creation is not implemented by this contract.

## Identity and transport boundaries

Firebase Authentication and Google Sign-In belong only to the iOS app target. Shared runtime and preview packages do not import either SDK. Apple and Google provider credentials are exchanged through Firebase; only the resulting short-lived Identity Platform ID token belongs in the native API's Authorization header. The SDK owns session persistence and normal token refresh. The app must not persist its own ID-token cache or expose credentials to screen JavaScript.

The HTTP client uses HTTPS, does not follow redirects, and does not use cookies or response caching. User sign-out must revoke the human context without unlinking the device or removing screens. A token refresh is not recent user authentication and must never be treated as approval for sign-in or enrollment.

Cloud provider configuration remains a separate release dependency: the actual project, iOS client, callback scheme, Apple capability/provider setup, and existing browser-account continuity must be qualified. Missing or unresolved configuration must fail before opening provider UI. The Calendar OAuth callback and credentials remain separate from Cloud identity.

## Deliberately unavailable functionality

Cloud connection remains unavailable in onboarding. These APIs cannot enroll an installation, reserve a device slot, activate Cloud management, browse a screen catalog, or install content. No simulator route, browser cookie, OpenAI OAuth token, or permanent user token may substitute for the future installation credential.

The enrollment slice requires a durable pending/switching journal alongside Keychain credentials, recovery for mismatched journal/key states, and a recoverable activation result. An unknown activation outcome is not successful cancellation. Explicit offline disconnect requires persisted revocation of old authority and deferred remote cleanup; it must not permit stale Cloud commands after restart or a new Local pairing.

## Qualification

Automated qualification covers accepted fixture decoding, request construction, pagination, transport isolation, cancellation, and configuration rejection. App compilation verifies SDK integration but cannot qualify real sign-in. Live Google/Apple authorization, token refresh and revocation, account continuity, zero-workspace onboarding, installation recovery, physical devices, and accessibility remain release gates before Cloud onboarding is enabled.
