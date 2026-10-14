# Lemon Bot for Apple platforms

Native SwiftUI clients for the independent Lemon Bot product backend. macOS and iOS share the `LemonBotKit` Swift package, Codable resources, product-session transport, observable live state and native `LemonBotUI` screens. They never connect to Lemon's operator WebSocket or receive its credential. The [canonical API](../contracts/api.md), [wire types](../contracts/protocol.ts) and [card lifecycle](../contracts/cards.md) define server behavior; this README describes packaging and platform use, not a second protocol.

## Generate, build and launch

Requirements: Xcode 26.3, XcodeGen 2.46+, the iOS simulator runtime, and access to the SwiftTerm package dependency. Run these commands from this `apple` directory:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
open LemonBot.xcodeproj

# Signing-independent CI builds:
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build

# Launch the generated macOS app:
open '.derivedData/Build/Products/Debug/Lemon Bot.app'

# Install and launch on an already booted iOS simulator:
xcrun simctl install booted '.derivedData/Build/Products/Debug-iphonesimulator/Lemon Bot.app'
xcrun simctl launch booted org.lemonbot.ios
```

Select **LemonBotMac** or **LemonBotiOS** in Xcode for interactive Run. `LemonBotShare` is a separate embedded iOS extension, not a second account client. Choose a concrete simulator in Xcode or boot an available simulator before `simctl install`; the generic build destination does not boot one.

The checked-in specification uses `org.lemonbot.mac`, `org.lemonbot.ios`, `org.lemonbot.ios.share` and App Group `group.org.lemonbot.shared`. For physical devices/distribution, register your own identifiers and matching App Group, update the project settings and entitlements together, enable Push Notifications on the iOS app identifier, and set your signing team in Xcode or pass `DEVELOPMENT_TEAM=<team>`. APNs also requires the backend's configured key, team, topic and environment; an unsigned simulator build is not evidence of APNs delivery. Device OS permission and backend capability are separate.

Enter the product origin (for local development `http://127.0.0.1:4080`, not Lemon `/ws`) in onboarding. On a physical phone use a reachable HTTPS backend hostname; phone loopback is the phone. Production requires HTTPS/WSS. Bootstrap with the operator's one-use setup code only on an empty deployment; otherwise local sign-in, invitation acceptance, or a configured OIDC provider. OIDC native completion requires `lemonbot://auth/complete` in the operator's client-redirect allowlist. The backend's confidential IdP credential stays server-side; native flow uses PKCE.

Accounts are stored in Keychain, keyed by backend/account. Account switching keeps workspace state separate. Sign-out revokes the session and removes its local account cache. There is no refresh token or mutation retry queue: uncertain work remains identifiable for reconciliation, not silently resubmitted.

## Native workspace

The primary navigation is a named Bot roster, with pinned Bots, synced sections, groups, hidden Bots and unread/activity indicators. macOS uses roster, conversation and inspector; iOS adapts split navigation to the available width. Bot identity, Job and scoped Memory remain distinct. The selected Bot shows its actual execution machine, current work and reviewed artifacts, with Activity + Upcoming, Ideas that draft rather than execute, preference inspection/Undo, grants, templates and milestone evidence.

The transcript renders the declared entry/card families with attributable actors and durable states. Questions are ordinary non-secret fields; secrets use a masked write-only destination flow. Approvals show the exact target, Bot, host, review scope and consequences. Only the targeted user can explicitly act before expiry; approval is not proof an external action completed. Email/Slack/channel drafts expose edited recipients, target/thread, body and files before Send. Unknown delivery is not Sent. Replies, reactions and feedback never resolve gates. Stop reports the server's actual run state; queued, steering and interrupting labels come from the receipt.

Gate and destructive controls require an online authenticated connection; they are never queued for offline replay. Native OIDC uses `ASWebAuthenticationSession` with the exact one-time `flowId`/`completionCode` callback and the original PKCE verifier. File previews authorize first; HTML is shown inert rather than executing embedded scripts in a privileged client, and voice memos use authorized persisted audio with native playback controls.

Machines expose genuine enrollment commands, invite expiry and verified online/offline state, measured host information, capabilities, names-only secret management and destination-local files. Terminal access is a full-host privilege and uses a native SwiftTerm VT-compatible interactive PTY with input, resize, reconnect gap/exit and close handling, not a simulated transcript. Bulk management displays exact preview scope and server per-machine progress. Shared-machine Bots share that OS user's files, browser sessions and CLI credentials; personas are not isolation boundaries.

Host file transfer advances by actual decoded chunk length and reports the source's total byte size; every acknowledged write chunk is already on the destination. Terminal OSC52 clipboard requests are blocked; copying selected text is an explicit user action. External-event routine filters are rendered from registered per-event schemas, not an opaque JSON editor. A broad any-message listener starts unchecked and requires an explicit human opt-in bound to the exact Bot/binding/channel scope; template/copy data never supplies that authority.

Skills, routines, reviewed memory import, templates, search, inbox, workspace and account management use the same authenticated API on both platforms. Routines expose actual test-run impact/history and one-time webhook keys. Settings include policy/effective authority, usage and spend limits, identity/directory governance, applied network revisions/egress, setup manifests/runs, audit/content exports and configured connectors/channels/email/X. Provider-dependent operations report backend prerequisites/errors; adding a connector is not authentication, and an unapplied host policy is not enforcement. External provider credentials and host drivers must be configured according to the product deployment guide.

## Explicit platform capture and voice

**macOS:** menu bar access, optional single selected-Bot compact companion, configurable global summon and hold-to-talk shortcuts. Dictation/PTT displays microphone ownership and on/off cues; release produces editable **unsent** text for review, and cancellation discards capture. The summon composer accepts explicitly selected text/files only. It does not capture screens, monitor clipboard history, listen ambiently, or create a virtual desktop per Bot.

**iOS:** explicit camera, Photos, Files and share-sheet input. The share extension copies user-selected content into durable App Group staging before completing; the app lets the user choose the account/conversation and retains files in the composer through chat switches. Shared content is not sent automatically. Microphone/Speech/camera/photos permissions belong to iOS; denied permission is not a backend capability error.

Voice uses Apple Speech for dictation and an explicit visible active-call loop, ordinary conversation messages and actual reply audio. Review applies before ordinary dictation Send. AVSpeechSynthesizer is an explicitly labeled local TTS fallback, not a persisted voice memo; persisted memo/sample downloads require actual server audio. iOS follows audio-session interruption policies and makes no background continuous-listening promise. Quick Look previews authorized downloaded files where the platform supports them; unsupported formats remain downloadable.

Notifications register the current installation to the current product account. iOS uses its actual APNs token; macOS uses local notifications. Same-device foreground viewed-conversation suppression does not clear inbox/unread or pending gates. Token-free `lemonbot://workspace/...` links fetch and authorize the exact task/entry/approval/machine/routine before navigation, never automatically approve.

## Centralized checks

Implementation agents intentionally do **not** run generation, builds, tests, formatters or live provider checks. The integration owner should run the commands above, then:

```sh
# Foundation wire/transport/cursor/draft lifecycle tests:
swift test --package-path LemonBotKit
# Native destructive-scope/error/pagination/task-target decoding tests:
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Exercise a real backend and attached host: setup/login/OIDC and account switch; draft retention; streaming reconnect and cursor expiry; stale/expired/other-user gates; uncertain send reconciliation; files and interactive PTY; voice permissions/review/mute/end; share extension interrupted import; foreground notifications and exact task deep links; provider prerequisites and applied host-policy revisions. Build/test success does not substitute for actual signing/APNs, configured provider or host-driver probes.

## Native product changes

The native product is separate from Lemon Web/TUI. It adds the shared Apple package and platform apps, complete typed transcript/action surfaces, account-bound realtime/drafts, native interactive host tools, explicit platform input/voice, notifications and privacy-bounded companion/share workflows. No screen streaming, ambient capture, operator-token client storage or automatic destructive mutation replay is introduced.
