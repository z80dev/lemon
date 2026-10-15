# Lemon Bot for Apple platforms

Native SwiftUI clients for the independent Lemon Bot product backend. macOS and iOS share the `LemonBotKit` Swift package, Codable resources, product-session transport, observable live state and native `LemonBotUI` screens. They never connect to Lemon's operator WebSocket or receive its credential. The [canonical API](../contracts/api.md), [wire types](../contracts/protocol.ts) and [card lifecycle](../contracts/cards.md) define server behavior; this README describes packaging and platform use, not a second protocol.

## End-user release packaging

End users open the notarized DMG, drag **Lemon Bot** to **Applications**, and launch
it normally. They do not need Xcode, Metal, XcodeGen, Bun, Node or a source checkout.
The arm64 Mac package requires macOS 14+. iPhone distribution is through App Store
Connect/TestFlight, not a simulator bundle renamed to an IPA.

The release builder requires macOS, Python 3, Xcode 26.3 selected through
`DEVELOPER_DIR`, XcodeGen 2.46+, the Xcode Metal Toolchain, and access to Swift
package dependencies. Install/accept those prerequisites on CI before packaging.
Run from this directory; output must be outside this source directory:

```sh
python3 release.py macos --version 2026.10.14 --build 1 \
  --channel preview --output /tmp/lemon-bot-apple-release
python3 release.py ios --version 2026.10.14 --build 1 \
  --channel preview --output /tmp/lemon-bot-apple-release
# Explicitly authorizes the actual App Store Connect upload:
python3 release.py ios-upload --version 2026.10.14 --build 1 \
  --channel preview --output /tmp/lemon-bot-apple-release
```

Pass the parent release's exact CalVer/channel and a monotonically increasing
Apple build number. Apple's three-component marketing version is the numeric
year.month.patch; the exact parent CalVer is retained in
`LemonBotReleaseVersion`, with `LemonBotReleaseChannel` in every app/extension
Info.plist. Device registration reads the real marketing version. Backend/API
compatibility versions remain the backend's declared contract, not this build number.

Signed Mac inputs: `APPLE_TEAM_ID`, `APPLE_DEVELOPER_ID_APPLICATION` (full
`Developer ID Application: …` identity with its private key installed in the
builder keychain), `APPLE_NOTARY_KEYCHAIN_PROFILE` (created externally with
`xcrun notarytool store-credentials`), and
`APPLE_MAC_PROVISIONING_PROFILE_SPECIFIER` for the app's registered identifier
and Release entitlements. The builder authenticates before compiling, preserves
the provisioned Release APNs configuration, uses hardened runtime, verifies the
signature, requires notarization **Accepted**, staples/validates the app and DMG,
and assesses the app with Gatekeeper. The local-preview mode alone uses Debug
entitlements without APNs. No security setting, Keychain loader, iOS entitlement,
bundle identifier or QR behavior is changed.

iOS inputs: `APPLE_TEAM_ID`, `APPLE_IOS_EXPORT_OPTIONS` (external export plist
with `method=app-store-connect`, `destination=export`, matching `teamID`, signing
style and appropriate app/share provisioning profile mappings if manual),
`APPLE_ASC_KEY_ID`, `APPLE_ASC_ISSUER_ID`, and `APPLE_ASC_KEY_PATH` (readable `.p8`).
The team must own the registered app/share identifiers, App Group and push
capability, valid Apple Distribution signing private key/certificate and App
Store provisioning profiles; automatic provisioning requires API-key permission.
The API key must also have App Store Connect upload permission and the app record
must already exist. The builder archives generic **device iOS**, exports a real
IPA with Xcode, and `ios-upload` submits it through Apple's `altool` API-key path.
Upload acceptance is not processing success, TestFlight availability, beta review
approval or App Store publication. Check those external receipts in App Store Connect.

Missing credentials fail closed; the currently reported zero signing identities
and only `HEX_API_KEY` repository secret cannot produce normal Apple distribution.
No release mode silently falls back to unsigned/ad-hoc output. For the integration
owner's packaging smoke only, explicitly run:

```sh
python3 release.py macos-preview --version 2026.10.14 --build 1 \
  --channel preview --output /tmp/lemon-bot-apple-local-preview
```

This separately named `local-preview` Debug ad-hoc DMG/ZIP is **not notarized**
and not a normal end-user release. It preserves the local Debug Keychain identity
constraints documented below. Never publish it as a signed installer.

The builder emits artifacts and a JSON receipt only after all requested steps
succeed; it does not publish a release or create another workflow. Receipt fields:
`schemaVersion: 1`, `product: lemon_bot`, exact `version`, `channel`,
`appleMarketingVersion`, `appleBuildNumber`, `distribution` (`local-preview`,
`developer-id-notarized`, or `app-store`), `uploadAccepted` (transport only), and
`artifacts[]` with `filename`, `format` (`dmg`, `zip`, `ipa`), `platform`
(`darwin-arm64`, `ios`), lowercase `sha256`, integer `sizeBytes`.
Mac names are `lemon-bot-<CalVer>-<channel>-darwin-arm64-notarized.{dmg,zip}`;
preview replaces `notarized` with `local-preview`. iOS is
`lemon-bot-<CalVer>-<channel>-ios-app-store.ipa`. Canonical release integration
owns mapping these additional installer records into schema-2 manifests and
publication; local-preview records must not become normal installer entries.

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
2. On macOS choose **Connect iPhone → Create QR code**. Treat the QR, copied pairing link and screenshots as temporary secrets. No operator token, desktop session token or permanent credential is encoded.
3. On iPhone choose **Scan QR code** or paste the link and choose **Check pasted link**. Check the workspace name, server address and expiry before choosing **Request connection**. Checking does not use up the code.
4. Compare the device name and six-digit verification code on both devices. On the Mac choose **Approve this iPhone** or **Deny**. Approval does not mean the phone has finished connecting.
5. On iPhone choose **Check my request** to finish connecting. Its own device-bound session is saved in Keychain; no desktop password is needed.

If a response is lost, **Check previous QR code** on Mac and **Check my request** on iPhone check the saved request rather than creating a second one. The QR keeps its original five-minute expiry. After an explicit expired or denied result, discard the saved request and create a new QR as a separate action. A successfully installed session stays valid until revoked.

Revoke the phone through **Settings → Account → Registered devices** or **Product sessions**. Device removal revokes its bound session; the phone shows explicit reconnect, not fake offline success. Camera, speech, share-sheet staging and selected files remain independent of pairing; no ambient capture or automatic send is introduced.
## Connection recovery

The sidebar connection pill opens the same recovery panel on Mac and iPhone.
Mac also shows it above the conversation after a failed connection attempt;
normal initial synchronization does not flash an error. The panel distinguishes
an unreachable Lemon Bot service, device network/TLS/DNS problems, server/proxy
errors, revoked sign-in and a reachable backend whose Lemon link is down. It
shows the target account/address, last error details with Copy, and the live
retry countdown. **Try again** bypasses the current backoff. Cached conversations
and unsent drafts remain available.

**Choose another Lemon Bot…** lists saved accounts and performs credential-free,
two-second public setup probes at saved origins and the two local development
addresses. Discovery is not a LAN scan or automatic sign-in. A discovered origin
opens prefilled onboarding; **Enter address…** accepts another secure address.
Physical iPhones start with an empty address and a tailnet HTTPS placeholder,
not the phone's own loopback address. Simulator keeps the development default.

When the backend is reachable, owners can start/restart Lemon through its
configured runtime launcher; owners/admins can reconnect a rejected or stopped
Lemon link. Restart requires confirmation. Running operations are observed by
read-only polling and expose the backend's bounded command output, never an
automatic mutation replay. An unconfigured launcher reports its actual reason.

The Mac app remains sandboxed: when the backend itself is down at a loopback
address, **Start it on this Mac** offers `lemon daemon`, the integrated-checkout
backend command, setup documentation and **Open Terminal**. It never spawns
Lemon or reads an operator token. Background reconnect detects the service when
it returns; failed local onboarding also probes until it answers. These local
commands and Terminal actions are not shown on iPhone.

## Lemon instance

**Settings → Lemon instance** shows the backend this account is attached to,
its version/address/start time, the Lemon controller link and its last error,
and the live Lemon version, uptime, memory, runs, sessions, nodes, channels and
skills. Missing measurements stay unavailable instead of becoming zero. Owners
and admins can view it and reconnect the link; other members see an explanation
without fetching privileged instance data. About links here for service status
and keeps client/worker compatibility and safe handoff diagnostics separate.

Owners can **Start**, **Restart** or **Stop** only when the backend reports
runtime control is configured. Stop and Restart explain the interruption and
require explicit confirmation. Admins cannot issue owner-only lifecycle commands.
When controls are unavailable, the backend's reason is shown. The shared pane
is also available from **View instance details** in the connection panel.
Status sections appear before Lifecycle. **Start** is unavailable while the Lemon link is connected.

On Mac, switching Settings panes keeps unfinished Preferences and local-platform edits in place. Sign-out asks for confirmation. When a voice message isn't confirmed, check its conversation before choosing **Start new voice message**; this discards the reviewed recording, never resends it, and does not bypass any pending-message check.

The pane refreshes every 10 seconds while visible, and every 2 seconds while a
command is running, with Refresh and iOS pull-to-refresh for a manual read.
Operation state and bounded output are the backend's actual receipt, with Copy
inside Details. A lost command response stays fenced; refresh never replays it.
The `instance-pane` and `instance-running` Mac snapshot scenes exercise the
settings registration and active-operation display in light and dark.




## Native workspace

The app is messaging-first. The sidebar holds search and new-Bot buttons, pinned Bot avatars, Inbox and Activity entries, Bot rows (lemon avatar, name, label chip, last-message preview, unread dot), groups and tasks, and at the bottom the account avatar (opens Settings) and **Connect apps**. A conversation has a floating Bot pill that toggles the inspector (Activity, Details, Library), grouped bubbles, a live "working…" row and a floating composer. Machines, connectors, channels, policies, usage and exports, account, devices, **Connect iPhone** and workspace admin live in **Settings**: the standard Settings window on macOS, a pushed list on iOS. Design tokens and shared components are in `LemonBotKit/Sources/LemonBotUI/Design/`.

The primary navigation is your named Bot roster, with pinned Bots, synced sections, groups of your own Bots, hidden Bots and unread/activity indicators. macOS uses roster, conversation and inspector; iOS adapts split navigation to the available width. Bot identity, Job and assigned-profile Memory remain distinct. The selected Bot shows its actual owned desktop/swarm host, current work and reviewed artifacts, with Activity + Upcoming, Ideas that draft rather than execute, preference inspection/Undo, native capability review, templates and milestone evidence. Live Team Bots, managers, publishing, membership controls and enterprise-first navigation are absent; workspace/public templates remain reviewed declarative copies, not live access grants.

On iPhone the composer stays in the bottom safe area above the software keyboard,
including its Send button. Return (including Shift+Return on a hardware keyboard)
inserts a newline; tap Send or use ⌘Return to send without dismissing the keyboard.
Long drafts scroll inside the multiline editor; landscape limits its visible
height so the transcript and Send button still have room above the keyboard.
In landscape, **+ → Last send details** retains receipt details without taking
space from the transcript; errors and unconfirmed outcomes remain visible inline.
Drag the transcript downward to dismiss the keyboard interactively. A transcript
already at the latest message stays there when the keyboard or composer resizes;
reading older messages does not force a jump to the bottom.

Groups have one human owner and two to six Bots owned by that person. There are no human invitations, successor transfer or Group Leave. Deletion uses the existing exact preview/confirmation and verified active/unknown-work lifecycle. Authoritative conversation deletion removes only this account's room draft and copied staging files, not selected originals or another account's cache. Legacy cached foreign live Bots/rooms do not regain visibility during offline restoration.

The transcript renders the declared entry/card families with attributable actors and durable states. Questions are ordinary non-secret fields; secrets use a masked write-only destination flow. Approvals show the exact target, Bot, host, review scope and consequences. Only the targeted user can explicitly act before expiry; approval is not proof an external action completed. Email/Slack/channel drafts expose edited recipients, target/thread, body and files before Send. Unknown delivery is not Sent. Replies, reactions and feedback never resolve gates. Stop reports the server's actual run state; queued, steering and interrupting labels come from the receipt.

A saved authored message does not mean every target admitted work. Per-target **Rejected** delivery retains the matching failed run's actual refusal reason, with no fabricated start or blanket unknown result; mixed group receipts keep admitted work independent. Message reconciliation reads the original actor/conversation/nonce receipt rather than dispatching another message.

After a lost/late HTTP acknowledgement or an envelope-less relay 502/504, native clients automatically read that receipt. Matching realtime entry/run observations, a caught-up reconnect and app foreground also recheck pending messages. A complete receipt clears the composer fence/error and only the unchanged captured draft; a partial group, missing reservation or unavailable read stays uncertain. Rejected/failed targets retain their actual errors. No message POST is automatically replayed.

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

Foreground presence belongs to its realtime connection, independently of message delivery. A refresh or background reconnect can retire a presence write; that old socket's failure is not a delivery failure on the replacement connection. Current-connection failures remain visible, and a missing message HTTP acknowledgement retains its original nonce until authoritative read-only reconciliation settles it. Realtime ACKs use the delivered frame's cursor, not a newer global HTTP snapshot watermark.

## Centralized checks

Implementation agents intentionally do **not** run generation, builds, tests, formatters or live provider checks. The integration owner should run the commands above, then:

```sh
# Foundation wire/transport/cursor/draft lifecycle tests:
swift test --package-path LemonBotKit
# Native destructive-scope/error/pagination/task-target decoding tests:
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

DEBUG-only visual check. The `LemonBotSnapshots` scheme renders the real views with in-process fixture data, in light and dark, to `/tmp/lb-ux/after/apple-*.png`. Set `TEST_RUNNER_LB_SNAPSHOT_DIR` to write somewhere else. The iOS app launched with `-LBFixtures` in a Debug build opens the same fixture workspace. Fixture message sends record text in memory for that fixture session only; they never execute Bot work or contact a backend. Other non-bookkeeping mutations remain read-only.
Use `-LBFixtures -LBFixtureScene backend-down` (or `controller-down` /
`reconnect-required`) to inspect the shared connection sheet on an isolated iOS
simulator. The Mac snapshot slugs match these names and include light/dark views.

```sh
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotSnapshots \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:LemonBotSnapshotTests
```

The `LemonBotKeyboard` UI-test scheme exercises short and multiline drafts, soft
Return, visible Send with the keyboard up, and transcript following in portrait
and landscape on a dedicated iPhone simulator:

```sh
xcodebuild -project LemonBot.xcodeproj -scheme LemonBotKeyboard \
  -destination 'platform=iOS Simulator,id=<your-simulator-UDID>' \
  -derivedDataPath /tmp/lemonbot-keyboard-build CODE_SIGNING_ALLOWED=NO test
```

Exercise a real backend and attached host: setup/login/OIDC and account switch; desktop HTTPS-publicUrl QR issuance; phone scan/paste exact preview, matching-code approve/deny, pending reopen, lost issuance/claim/completion receipt recovery, expired re-pair, Keychain restart, offline return, same Bot/conversation restore and device/session revocation. Also exercise draft retention; streaming reconnect and cursor expiry; stale/expired gates; uncertain send reconciliation; owner groups and profile memory; files and interactive PTY; voice permissions/review/mute/end; interrupted share import; notifications/task links; provider prerequisites and applied host policy. Build/test success does not substitute for real camera permission, physical-device TLS/Tailscale reachability, signing/APNs or configured host/provider probes.

## Native product changes

The native product is separate from Lemon Web/TUI. It adds the shared Apple package and platform apps, complete typed transcript/action surfaces, account-bound realtime/drafts, native interactive host tools, explicit platform input/voice, notifications and privacy-bounded companion/share workflows. No screen streaming, ambient capture, operator-token client storage or automatic destructive mutation replay is introduced.

The owner-assistant cutover adds strict named pairing Codable DTOs and nullable session expiry, actual desktop QR/phone scanner, verified preclaim cluster preview, device-local Keychain reconciliation and persistent account/selection restoration. Removed Team/connector-consent/card/event fields are not retained as compatibility shims; assistant, own-Bot groups, host tools, voice/share privacy and unknown mutation lifecycle remain native product APIs.


Wire-array decoding and encoding preserve the exact feedback-reason, export-stream and X-media literal sets, rejecting unsupported elements without dropping fields or substituting opaque JSON. Optional array omission remains distinct from invalid null. Nullable actor IDs and public `protocol:`/`as:` argument labels use unambiguous Swift types and identifiers.

On macOS, native conversation input handles Return key events with their modifiers, retaining Shift+Return for a newline; iOS uses multiline Return and the visible Send button. Decision eligibility reads stay on the main actor, and replaying a finished voice memo awaits the native seek before playback. Composer and routine-editor composition is split into typed view sections and explicit action handlers while retaining draft/file/routing controls, delivery reconciliation, trigger consent, run history and one-time webhook-key review. The native VT delegate conformance is main-actor isolated to match its UI-thread callback invariant, and destructive-preview completion callbacks are explicitly labeled.

Store lifecycle tests inject an isolated credential store within the test target; production still defaults to Keychain and reports credential-access/deletion failures without an insecure fallback. Cursor-expiry fixtures serve complete authorized resource pagination and opened transcripts, checking read-only recovery, access eviction and local-draft retention without requiring a private request order.

The macOS app keeps separate workspace, settings and menu-bar scenes, with typed layout, toolbar, commands and event sections. This preserves summon/active-call actions, user-selected input requests, account-bound voice cleanup, deep links, companion updates and foreground/viewed-room presence without type-erased scene or view wrappers.

macOS registers its selected-text Services provider from the started workspace lifecycle, after AppKit has initialized—not from the SwiftUI app's controller constructor. iOS terminal colors use SwiftTerm's actual UIKit foreground/background APIs; native voice bindings mutate the existing capture object without replacing its owner.

Release packaging now provides explicit Developer ID notarized Mac DMG/ZIP and
device iOS App Store archive/export/upload paths, fails closed on missing signing
inputs, and keeps local ad-hoc packaging separate. Generated release bundles use
parent CalVer/build metadata rather than a hard-coded Mac app version.

Signed Mac packaging preserves the Release APNs entitlements and requires its
matching provisioning profile; only explicitly requested local-preview packaging
uses the non-provisioned Debug capability set.
