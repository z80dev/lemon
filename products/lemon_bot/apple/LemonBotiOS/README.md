# Lemon Bot on iPhone and iPad

The native SwiftUI application embeds `LemonBotRootView(store:)`, using the same authenticated product API and typed screens as the Mac app. The phone is a client, not an execution node. No desktop streaming, ambient microphone capture, unrestricted Photos scan, clipboard history or background audio entitlement is supplied.

## Signing and target inputs

The app target includes this directory excluding `ShareExtension/`. The share target includes `ShareExtension/ShareViewController.swift` and `Shared/ShareInbox.swift`; it does not link LemonBotKit or access account credentials. The share-extension handoff requires both targets to be signed with the App Group `group.org.lemonbot.shared`. Builds without it (for example, Personal Team device installs) keep in-app camera/photo/file staging in the app's own container, and the extension reports that sharing is unavailable. App bundle/topic defaults to `org.lemonbot.ios`, extension to `org.lemonbot.ios.share`.

When a share-extension build lacks App Group access, its review sheet explains
that sharing is unavailable and directs you to Camera, Photos or Files inside
Lemon Bot. It does not offer a retry that cannot fix signing. The App Group
identifier appears only in the developer log, not the error shown to users.

`APS_ENVIRONMENT` must be `development` for a sandbox-signed build or `production` for a production-signed build, consistent with the provisioning profile. Both `Info.plist` (`LemonBotAPNSEnvironment`) and the app entitlement (`aps-environment`) expand that same build setting. The app converts the actual OS device-token bytes to lowercase hexadecimal and maps `development` to the backend's `sandbox` registration environment. It never fabricates a simulator token or infers environment from an unrelated debug flag. Production APNs needs the operator's real key ID, team ID, private `.p8` key and allowlisted bundle topic; backend errors preserve the exact prerequisite and request ID.

Only local networking is exempted in App Transport Security for loopback development. An installed phone normally needs a reachable HTTPS backend; the phone's loopback address is not a development Mac's loopback address.

## Connect to your desktop

On the signed-in Mac choose **Connect iPhone → Check connection readiness**, review the verified address/instance/workspace, then **Create QR code**. On iPhone choose **Scan QR code or paste link**, then **Scan QR code**. Camera capture and its permission prompt start only after that explicit scan action, using the actual QR metadata camera output; leaving the screen or foreground stops capture. If Camera is unavailable (including Simulator), paste the one-use link into the secure field and choose **Check pasted link**.

The phone first runs the shared public preflight against the QR's exact origin and expected backend instance, then fetches the non-consuming workspace preview. Review the workspace name, origin, backend instance ID, workspace ID and original expiry before **Request connection**. Preview never claims or consumes the code; if it fails, **Check workspace** makes one explicit new read, not a retry loop. Reopening an unchecked or failed preview also waits for **Check workspace**, rather than retrying automatically. Wrong-service responses, instance mismatch and invalid TLS fail closed. Scanning/checking is not consent to request access.

After the explicit request, compare the six-digit verification code and exact device name on both devices. On Mac select **The exact device name and code match my iPhone**, then **Approve this iPhone**, or deny a mismatch. The active phone pairing screen observes the confirmed pending request and automatically completes after approval, bounded by the saved original expiry. Checks pause when the screen closes or the app loses foreground; they never claim or approve again. Normal approval needs no manual finish step. Before installing the completed credential, the phone verifies authenticated `/identity` with its own new session against the QR's expected instance and workspace, then saves that session and instance pin in Keychain. This is its own revocable device session, not a copy of the Mac credential; no manual password is required.

The resulting workspace distinguishes an actual verified online connection from a saved credential with initial sync still in progress or offline. Reconnect-required means saved access could not be verified or was revoked, not a successful connection. Never put QR screenshots, raw links, claim/completion authority or session tokens in logs, chat or push notifications.

The desktop's configured public URL must reach the **same already running Lemon Bot backend** over HTTPS, not Lemon Web or the operator WebSocket. The app never starts a backend or changes host routes. Tailscale Serve is recommended when Mac/phone reachability is already configured; use the exact advertised origin and connect both devices to the tailnet. Any operator-chosen route setup must preserve existing routes and use an unused HTTPS listener/port, never Funnel. A QR does not establish overlay trust or permit insecure TLS. Loopback HTTP is same-machine development/Simulator only; a physical phone's `127.0.0.1` is the phone, not the Mac.

Pending requests survive reopening with their original expiry and fixed nonces. Confirmed pending approval can resume foreground observation while unexpired. An unknown claim/completion or network outcome stops automatic checks; reopening never retries it. **Check my request** is the explicit reconciliation action for the original saved receipt, not a new claim or a new session. After an explicit denial or expiry, discard the local request and create a fresh QR separately.

Launch restores the saved Keychain account and foreground reconnect is read-only. When a pin exists, public setup must match before the saved token is sent; authenticated identity must then match the instance pin and workspace before sync or socket authentication. Legacy unpinned iOS accounts can pin only after an authenticated baseline is verified. Offline retains credentials/cache; an identity mismatch or revoked session requires explicit reconnect, retains cached content and pending-mutation fences, and never replays sends or approvals. Revoke the phone through desktop **Settings → Account → Registered devices** or **Product sessions**.

Temporary HTTP 502, 503 or 504 responses from setup/identity preflight remain
recoverable offline failures: the saved credential and identity pin are retained,
and retry/backoff repeats verification before enabling authenticated sync or
realtime. These outages do not require pairing again or replay pending mutations.

## Selected content and unsent drafts

1. In a conversation choose **Camera**, **Photos** or **Files**, or choose Lemon Bot in another app's Share sheet. Camera asks permission only when invoked. Photos uses Apple's selected-item picker without broad library authorization. Files uses security-scoped access only while copying selected files.
2. The share extension copies provider-owned temporary files inside the provider callback, before returning or completing the extension. **Save for review** publishes an atomic App Group manifest only after copies are complete. Review/edit selected text before saving. The extension never contacts the backend or sends a message.
3. Open **Selected shares** in the app. An extension capture starts without a conversation. Select the account and explicitly choose a conversation. Native composer captures are already bound to the account/workspace/user/conversation the user invoked.
4. **Attach to unsent composer** fetches that conversation's ACL and retained per-chat draft, binds the durable capture, then uploads selected files with individually persisted nonces. Only confirmed attachment IDs are appended to that same conversation's local draft. Selected text is appended with a persisted before/after snapshot so a restart between saving the draft and updating the manifest cannot append it twice or overwrite a changed draft.
5. Return to chat, review the text/files and press **Send** separately. Import never sends, approves, executes or queues anything offline. Transport/prerequisite errors stay with the capture and individual files. An explicit Attach retry uses the original upload nonce, not an automatically replayed mutation.

Local files remain in App Group storage across app launches and conversation switches until the user explicitly discards that capture. Discard removes only those staged local files: it does not delete existing draft content or uploaded server attachments. A bound capture cannot be silently retargeted across accounts or rooms. File limits are six per message, 25 MiB non-video and 200 MiB video; unreadable/unsupported inputs remain errors, not fake successful attachments.

## Reviewed speech and voice sessions

**Dictation** opens explicit Record/Stop/Cancel controls. Apple Speech uses on-device recognition when supported; otherwise its network-processing status is disclosed. Stop freezes the recognized text so a late callback cannot overwrite edits. **Add reviewed text to unsent composer** durably writes the chosen conversation's draft without sending. Microphone or Speech denial names the relevant iOS permission and offers Settings.

**Voice** starts only from an empty composer in your own direct chat or task. It registers a real device and creates the backend VoiceSession. Record each turn explicitly, stop, review/edit, and press **Send reviewed utterance** with that session ID. Streaming assistant sentences are spoken through configured backend speech and authorized audio download/playback when available, or a clearly labelled Apple `AVSpeechSynthesizer` fallback. The user can explicitly choose the Apple spoken voice. Provider errors retain the exact backend explanation rather than substituting generated silence.

The visible session banner survives navigation and offers Return/Hang up. The overlay includes mute, transcript, provider voice/language/speed, local spoken voice, duration, terminal call state and feedback. Existing-call conflicts fetch the authorized `details.voiceSessionId` and require the user to end it explicitly; another device's session never acquires this phone's microphone. Message outcomes that are unknown retain the reviewed utterance and fence its send button; no automatic resend. App launch reconciles a retained session ID but never restarts microphone capture.

Recording stops on interruption, inactive/background scene transitions and its one-minute safety boundary. There is no lock-screen or background call continuity promise. Work already sent continues in chat after a call ends.

## Notifications and exact links

OS notification authorization is independent of backend preferences/capability. **iOS access** displays OS permission, actual registration status, backend APNs capability and exact errors. `LemonBot.visibleConversationChanged` tracks the actually displayed conversation, not a remembered selection in Settings. Foreground device presence is refreshed within the backend's 60-second TTL. The native delegate suppresses foreground delivery only for the same workspace and actually visible room; other rooms still surface.

Notification taps and resource `lemonbot://` URLs go through LemonBotKit's strict task/entry/approval/machine/routine router and authenticated ACL fetches. Navigation never resolves a gate. Foreign/revoked/deleted targets preserve an error rather than opening unrelated content. `lemonbot://share` opens local selected content only. OIDC `lemonbot://auth/complete` belongs to the onboarding authentication session, not the resource router.

## Shared UI hooks

- `LemonBot.platformComposerRequest`: `conversationID`, `action` (`camera`, `photos`, `files`, `dictation`, `voice`, `stagedFiles`, `shares`). `stagedFiles` requests names of locally retained unuploaded files for that exact conversation; `shares` explicitly opens their review/import sheet.
- `LemonBot.platformStagedFilesChanged`: `conversationID` and `filenames`, updating native staged-file chips without uploading or sending.
- `LemonBot.visibleConversationChanged`: `conversationID` string on appearance, `NSNull` on disappearance.
- `LemonBot.platformNotificationsRequest`: explicit OS permission request.
- `LemonBot.platformSettingsRequest`: explicit opening of the app's iOS Settings pane.

These hooks cross the package/app boundary without introducing an app dependency into the shared UI library.

## Changelog

- Added explicit one-use desktop pairing, real QR scanning, secure paste/preview, saved pending reconciliation and saved-account startup with read-only foreground reconnect. Removed invitation-first onboarding and Team voice eligibility.
- Pairing now fetches the exact cluster name and expiry through a non-consuming preview before enabling a claim, including resumed preview state.
- A verified `preview_ready` state gates the explicit connection request. Camera authorization alerts no longer cancel the initial scan; actual background entry still stops capture, and configured capture stops on foreground loss.
- Phone pairing verifies the QR backend before preview/claim/completion, checks the new session's authenticated identity before saving an instance pin, and observes approval/completion automatically only on an active foreground screen within the original expiry. Unknown/network outcomes stop until explicit **Check my request** reconciliation. Saved-account restore verifies pinned identity before sync/socket authentication and distinguishes offline saved access from verified connection or reconnect-required; pairing presentation stays alive through the initial restore attempt.
