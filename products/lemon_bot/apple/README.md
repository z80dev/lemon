# Lemon Bot for Apple platforms

Native SwiftUI clients for the independent Lemon Bot product backend. macOS and iOS share the `LemonBotKit` Swift package, Codable resources, product-session transport, observable live state and native `LemonBotUI` screens. They never connect to Lemon's operator WebSocket or receive its credential. The [canonical API](../contracts/api.md), [wire types](../contracts/protocol.ts) and [card lifecycle](../contracts/cards.md) define server behavior; this README describes packaging and platform use, not a second protocol.

## Generate, build and launch

Requirements: Xcode 26.3, XcodeGen 2.46+, the iOS simulator runtime, the Xcode Metal Toolchain used by SwiftTerm, and access to the SwiftTerm package dependency. Run these commands from this `apple` directory:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Once per Xcode installation, if the Metal component is missing:
# xcodebuild -downloadComponent MetalToolchain
xcodegen generate --spec project.yml
open LemonBot.xcodeproj

# Compilation-only CI builds (do not launch these for sign-in/storage checks):
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build

# Quit the old Lemon Bot before rebuilding the runnable macOS app.
# Debug requests local ad-hoc signing without APNs/App Group capabilities:
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/lemonbot-owner-mac-build CODE_SIGNING_ALLOWED=YES build
open '/tmp/lemonbot-owner-mac-build/Build/Products/Debug/Lemon Bot.app'

# Install and launch on an already booted iOS simulator:
xcrun simctl install booted '.derivedData/Build/Products/Debug-iphonesimulator/Lemon Bot.app'
xcrun simctl launch booted org.lemonbot.ios
```

Select **LemonBotMac** or **LemonBotiOS** in Xcode for interactive Run. `LemonBotShare` is a separate embedded iOS extension, not a second account client. Choose a concrete simulator in Xcode or boot an available simulator before `simctl install`; the generic build destination does not boot one.

`CODE_SIGNING_ALLOWED=NO` is compilation-only, not a supported macOS login/Keychain smoke build. The macOS Debug target is configured for ad-hoc signing with the unchanged `org.lemonbot.mac` identity, a sandbox-only local entitlement file and an empty `APS_ENVIRONMENT`; it deliberately excludes the profile-requiring APNs entitlement and unused Mac App Group. Notifications in that configuration are local, not remote APNs. The integration owner must still build and exercise the resulting app: signing configuration is not proof of successful login or Keychain persistence. Keep the same installed bundle for save/quit/relaunch checks. Ad-hoc signatures do not provide a persistent signer across code-changing rebuilds: macOS may require normal Keychain authorization again. For persistent signer trust across rebuilds, use the same development signing identity/team (`CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=<team>`). Do not delete credentials or relax their access controls to bypass authorization errors.

Unsigned builds also do not grant App Group access. To exercise the real app/share container on a simulator, choose its concrete destination and build with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`, then install that signed bundle. Physical devices still require your registered identifiers, entitlements and signing team.

Both applications package the shared `Assets.xcassets/AppIcon.appiconset`, with opaque iOS artwork and all macOS icon sizes. `Brand.svg` is the editable product mark; the asset catalog's PNG files are checked-in packaging inputs, not build output.

The checked-in specification uses `org.lemonbot.mac`, `org.lemonbot.ios`, `org.lemonbot.ios.share` and the iOS app/share App Group `group.org.lemonbot.shared`; the Mac app does not consume that group. For physical iOS devices/distribution, register your own identifiers and matching App Group, update the project settings and entitlements together, enable Push Notifications on the iOS app identifier, and set your signing team in Xcode or pass `DEVELOPMENT_TEAM=<team>`. Mac Release retains its existing provisioned APNs entitlement and requires the corresponding signing profile/team; local Mac Debug omits it. APNs also requires the backend's configured key, team, topic and environment; an unsigned simulator build is not evidence of APNs delivery. Device OS permission and backend capability are separate.

Enter the product origin (for local development `http://127.0.0.1:4080`, not Lemon `/ws`) in desktop onboarding. Bootstrap with the operator's one-use setup code only on an empty deployment; otherwise use local sign-in or a configured OIDC provider. OIDC native completion requires `lemonbot://auth/complete` in the backend's client-redirect allowlist. Its confidential IdP credential stays server-side; native flow uses PKCE. iPhone onboarding prioritizes connecting to your already signed-in desktop, not enterprise setup or invitations.

Accounts and device-bound product credentials use native Keychain, keyed by exact backend/account. On macOS, all account and pending-pairing reads, updates, inserts and removals explicitly select the standard local login Keychain with synchronization disabled. Its encrypted, code-signing-ACL-protected items do not sync through iCloud; this is not a hardware-bound or backup-nonportable storage guarantee. On iOS, the same items retain `AfterFirstUnlockThisDeviceOnly` accessibility and synchronization is explicitly disabled. Backend device/session binding and revocation remain independent of the local storage implementation. The last account and selected Bot/conversation restore on launch. Account switching keeps workspace state separate; sign-out revokes the session and removes that account's local cache. Ordinary sessions keep bounded expiry; paired `AuthSession.expiresAtMs: null` means **until revoked**, not expired or a client-generated refresh token. Offline restoration retains the saved cluster, credential, drafts and last-known selection; reconnection performs reads/realtime subscriptions, never replays ordinary mutations. Authoritative revocation shows **Reconnect to your desktop** and disables old authority.

The platform split follows Apple's [macOS Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) and [`kSecAttrAccessible` contract](https://developer.apple.com/documentation/security/ksecattraccessible): iOS accessibility attributes require the data-protection Keychain on macOS, which has provisioned-entitlement requirements. They are not added to macOS login-Keychain items. There is no runtime fallback, credential/cache deletion, store migration or error suppression.

macOS account loading enumerates only this service's non-sync local Keychain item references, then reads each exact password individually. Apple's [`SecItemCopyMatching` contract](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)) forbids combining `kSecReturnData` with `kSecMatchLimitAll` for password items; that invalid bulk read must not be treated as an empty account list. Per-item reads preserve authorization errors and decoding failures rather than skipping credentials. iOS retains its existing data-protection-Keychain bulk loader.

An opaque creation timeout without returned IDs stays fenced when the server exposes no authoritative receipt. Likewise a private-resource 404 or unrelated newer revision does not prove the original deletion/edit completed. The inspector reports unresolved rather than inventing success or retrying; unknown Stop waits for an observed terminal run. Pairing has its own explicitly defined same-nonce receipt reconciliation below, not a general retry queue.

## Connect iPhone to your desktop

1. Configure the backend's reachable HTTPS `publicUrl`. **Tailscale Serve** is the recommended boring option when your Mac and phone already have Tailscale reachability. TLS must validate normally; a QR never attests an overlay or permits a remote HTTP/TLS bypass. HTTP loopback is only for same-machine development/Simulator; a physical phone's `127.0.0.1` is the phone, not the Mac. This client does not provision or sign in to Tailscale.
2. On macOS choose **Connect iPhone → Create one-use QR code**. CoreImage renders the backend-issued `pairUrl`, with the exact cluster/origin and original five-minute expiry. **Copy one-use pairing link** provides an explicit paste alternative; treat the QR, clipboard copy and screenshots as temporary secrets. No operator token, desktop session token or permanent credential is encoded, logged or sent in push.
3. On iPhone choose **Scan desktop QR** or paste the link. Camera permission and `AVCaptureMetadataOutput` capture start only from that explicit action and stop on leaving/backgrounding. Before requesting access, a nonconsuming, secret-bound `POST /pairings/preview` verifies the exact cluster name, origin and expiry. Strict bounded parsing rejects credentials, extra/duplicate query fields, unsafe origins and malformed one-use codes. A camera denial still leaves paste available.
4. Choose **Request connection**. Claim consumes the one-use code and shows the phone's verification code. The Mac previews that exact device name and matching six-digit code; the owner explicitly **Approves once** or **Denies**. Approval alone is not a claim of successful phone installation.
5. Choose **Check approval / finish connection**. A connected response supplies the phone's own device-bound product session; the app saves it to Keychain and restores normal account/Bot/conversation state without a manual desktop password. Pending claim/completion authority is also device-local Keychain state, so reopening can reconcile the original request rather than claiming another QR.

Every claim and completion retains its original nonce before networking. Pending checks and an explicitly reconciled lost response reuse the same completion nonce and return the **same** Device/AuthSession, never another credential. A lost desktop issuance response similarly uses **Reconcile original QR request** to recover the original one-use QR with its original nonce. Private receipt replay ends at the original five-minute pairing deadline; after explicit expired/denied state, discard the local request and create a fresh QR as a separate human action. The successfully installed session itself remains valid until revoked.

Revoke the phone through **Settings → Account → Registered devices** or **Product sessions**. Device removal revokes its bound session; the phone shows explicit reconnect, not fake offline success. Camera, speech, share-sheet staging and selected files remain independent of pairing; no ambient capture or automatic send is introduced.


## Native workspace

The primary navigation is your named Bot roster, with pinned Bots, synced sections, groups of your own Bots, hidden Bots and unread/activity indicators. macOS uses roster, conversation and inspector; iOS adapts split navigation to the available width. Bot identity, Job and assigned-profile Memory remain distinct. The selected Bot shows its actual owned desktop/swarm host, current work and reviewed artifacts, with Activity + Upcoming, Ideas that draft rather than execute, preference inspection/Undo, native capability review, templates and milestone evidence. Live Team Bots, managers, publishing, membership controls and enterprise-first navigation are absent; workspace/public templates remain reviewed declarative copies, not live access grants.

Groups have one human owner and two to six Bots owned by that person. There are no human invitations, successor transfer or Group Leave. Deletion uses the existing exact preview/confirmation and verified active/unknown-work lifecycle. Authoritative conversation deletion removes only this account's room draft and copied staging files, not selected originals or another account's cache. Legacy cached foreign live Bots/rooms do not regain visibility during offline restoration.

The transcript renders the declared entry/card families with attributable actors and durable states. Questions are ordinary non-secret fields; secrets use a masked write-only destination flow. Approvals show the exact target, Bot, host, review scope and consequences. Only the targeted user can explicitly act before expiry; approval is not proof an external action completed. Email/Slack/channel drafts expose edited recipients, target/thread, body and files before Send. Unknown delivery is not Sent. Replies, reactions and feedback never resolve gates. Stop reports the server's actual run state; queued, steering and interrupting labels come from the receipt.

A saved authored message does not mean every target admitted work. Per-target **Rejected** delivery retains the matching failed run's actual refusal reason, with no fabricated start or blanket unknown result; mixed group receipts keep admitted work independent. Explicit reconciliation uses the reserved IDs/nonce rather than dispatching another message.

Gate and destructive controls require an online authenticated connection; they are never queued for offline replay. Native OIDC uses `ASWebAuthenticationSession` with the exact one-time `flowId`/`completionCode` callback and the original PKCE verifier. File previews authorize first; HTML is shown inert rather than executing embedded scripts in a privileged client, and voice memos use authorized persisted audio with native playback controls.

Machines expose genuine enrollment commands, invite expiry and verified online/offline state, measured host information, capabilities, names-only secret management and destination-local files. Terminal access is a full-host privilege and uses a native SwiftTerm VT-compatible interactive PTY with input, resize, reconnect gap/exit and close handling, not a simulated transcript. Bulk management displays exact preview scope and server per-machine progress. Shared-machine Bots share that OS user's files, browser sessions and CLI credentials; personas are not isolation boundaries.

Host file transfer advances by actual decoded chunk length and reports the source's total byte size; every acknowledged write chunk is already on the destination. Terminal OSC52 clipboard requests are blocked; copying selected text is an explicit user action. External-event routine filters are rendered from registered per-event schemas, not an opaque JSON editor. A broad any-message listener starts unchecked and requires an explicit human opt-in bound to the exact Bot/binding/channel scope; template/copy data never supplies that authority.

Skills, routines, reviewed assigned-profile memory import, templates, search, inbox, cluster and account management use the same authenticated API on both platforms. Routines expose actual test-run impact/history and one-time webhook keys. Settings retain owner account/preferences, host policy/effective authority, usage/spend, applied network revisions/egress, audit/content exports and configured connectors/channels/email/X; enterprise membership/directory/SCIM/setup-manifest panels are removed. OAuth accounts remain owned; obsolete cross-human connector-lending consent and shared-account fields are gone. Provider-dependent operations report actual backend prerequisites/errors; adding a connector is not authentication, and an unapplied host policy is not enforcement.

Mailbox indexing warnings appear only for a real provider-reported delay, with the observation time/age; missing observations remain unknown rather than implying an up-to-date mailbox. The address flow is availability check → exact scoped proposal → targeted approval → actual provider claim, never a synthetic local mailbox.

After account deletion revokes its sessions, an enabled workspace Owner can read the bounded cleanup-operation list/details, keeping product removal separate from each actual provider's receipt/status. Refresh is read-only and never replays deletion or provider revocation. The deleted client retains only safe opaque user/operation/request diagnostics for handoff, with copy/clear controls available at sign-in; it does not retain an authorization capability or restore deleted login. Pending X connections display **Account not yet verified**, not an invented username/account identity.

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

Exercise a real backend and attached host: setup/login/OIDC and account switch; desktop HTTPS-publicUrl QR issuance; phone scan/paste exact preview, matching-code approve/deny, pending reopen, lost issuance/claim/completion receipt recovery, expired re-pair, Keychain restart, offline return, same Bot/conversation restore and device/session revocation. Also exercise draft retention; streaming reconnect and cursor expiry; stale/expired gates; uncertain send reconciliation; owner groups and profile memory; files and interactive PTY; voice permissions/review/mute/end; interrupted share import; notifications/task links; provider prerequisites and applied host policy. Build/test success does not substitute for real camera permission, physical-device TLS/Tailscale reachability, signing/APNs or configured host/provider probes.

## Native product changes

The native product is separate from Lemon Web/TUI. It adds the shared Apple package and platform apps, complete typed transcript/action surfaces, account-bound realtime/drafts, native interactive host tools, explicit platform input/voice, notifications and privacy-bounded companion/share workflows. No screen streaming, ambient capture, operator-token client storage or automatic destructive mutation replay is introduced.

The owner-assistant cutover adds strict named pairing Codable DTOs and nullable session expiry, actual desktop QR/phone scanner, verified preclaim cluster preview, device-local Keychain reconciliation and persistent account/selection restoration. Removed Team/connector-consent/card/event fields are not retained as compatibility shims; assistant, own-Bot groups, host tools, voice/share privacy and unknown mutation lifecycle remain native product APIs.


Wire-array decoding and encoding preserve the exact feedback-reason, export-stream and X-media literal sets, rejecting unsupported elements without dropping fields or substituting opaque JSON. Optional array omission remains distinct from invalid null. Nullable actor IDs and public `protocol:`/`as:` argument labels use unambiguous Swift types and identifiers.

Native conversation input handles Return key events with their modifiers, retaining Shift+Return for a newline. Decision eligibility reads stay on the main actor, and replaying a finished voice memo awaits the native seek before playback. Composer and routine-editor composition is split into typed view sections and explicit action handlers while retaining draft/file/routing controls, delivery reconciliation, trigger consent, run history and one-time webhook-key review. The native VT delegate conformance is main-actor isolated to match its UI-thread callback invariant, and destructive-preview completion callbacks are explicitly labeled.

Store lifecycle tests inject an isolated credential store within the test target; production still defaults to Keychain and reports credential-access/deletion failures without an insecure fallback. Cursor-expiry fixtures serve complete authorized resource pagination and opened transcripts, checking read-only recovery, access eviction and local-draft retention without requiring a private request order.

The macOS app keeps separate workspace, settings and menu-bar scenes, with typed layout, toolbar, commands and event sections. This preserves summon/active-call actions, user-selected input requests, account-bound voice cleanup, deep links, companion updates and foreground/viewed-room presence without type-erased scene or view wrappers.

macOS registers its selected-text Services provider from the started workspace lifecycle, after AppKit has initialized—not from the SwiftUI app's controller constructor. iOS terminal colors use SwiftTerm's actual UIKit foreground/background APIs; native voice bindings mutate the existing capture object without replacing its owner.
