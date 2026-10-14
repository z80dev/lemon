# Native macOS app

`LemonBotMacApp` hosts the shared `LemonBotRootView(store:)` and one menu-bar entry. Requires macOS 14+, the shared LemonBotKit/LemonBotUI products, and the authenticated product backend. The Apple project owns build/signing settings; this directory supplies `Info.plist` and `LemonBotMac.entitlements`.

## Connect iPhone

Open **Connect iPhone** from the signed-in workspace, create a one-use QR and leave the request list open. The QR is rendered locally with CoreImage, using only the one-use link returned by the backend. On the phone scan or securely paste it, verify the exact origin/cluster, and request connection. Match the exact device name and verification code shown on both devices before **Approve this device once**; deny unfamiliar requests. The UI shows the canonical cluster name, backend URL and expiry. **Refresh requests** reads authoritative state without repeating mutations; unconfirmed approval/denial remains fenced.

Configure the backend public URL to reachable HTTPS before creating the QR. Tailscale Serve is the recommended HTTPS front door to a local backend; both devices need tailnet reachability and the configured public URL must match that exact origin. Never use remote plain HTTP or infer transport trust from a QR. Loopback HTTP is for same-Mac development and iOS Simulator only, not a physical phone.

The phone completes approval explicitly and receives its own Keychain-backed revocable session without your password. Revoke it through account Devices / sessions, using the real device/session revoke controls. Launch restores the last saved account; foreground reconnect reads state only, retains offline credentials and does not replay mutations. Revocation requires explicit reconnection. Treat the QR as a temporary secret: do not log or share its link or screenshot.

## Explicit companion and capture

Open **Lemon Bot → Settings** to choose a Bot and optionally enable one compact companion. Global summon and push-to-talk are disabled by default. Enter combinations such as `control+option+space` or `command+shift+f8`; clear a field to disable it. Carbon registers only those combinations and reports registration conflicts. There is no global keyboard monitor or Accessibility permission.

Summon opens the selected Bot’s same shared mini-composer, labelled with account/workspace/machine. **Services → Send selection to Lemon Bot** imports only the selection provided by the invoking application; **Choose files** uses the native user-selected file picker. Content stays in that conversation’s draft until explicit Send. No screen reading, desktop streaming, clipboard polling/history, ambient listening or wake-word capture exists.

Device/account settings persist through `LemonBotStore.saveLocalSettings(_:)` as the exact `ClientLocalSettings` fields; this is device-local, not an invented settings HTTP endpoint.

## Voice

The macOS settings window lists actual Core Audio microphone inputs. Choose a device or **System default** and refresh after plugging in hardware; a disconnected selected device reports an error rather than silently selecting another microphone. This hardware choice is local to this Mac, changes only the explicit capture audio unit, and does not grant microphone access to a remote Bot.

Holding the configured PTT combination requests microphone/Speech authorization on first use, shows a microphone-on owner/target panel, records only while held, and plays optional mic-on/off cues. Release turns the microphone off and transcribes for editable review. Escape/Discard clears the temporary recording and text. Apple Speech requires on-device recognition; if unavailable/denied, the reviewed recording can be **explicitly** uploaded for backend transcription. Backend prerequisites/errors are shown verbatim through the shared API errors. Capture is bounded to ten minutes and stops when the voice panel closes, the account changes or the app quits.

**Keep as unsent draft** appends reviewed text to the original conversation, preserving existing attachments/reply. It never sends. An explicit active voice chat is a backend VoiceSession: Record → Stop/review → **Send reviewed utterance** uses ordinary message sending with `voiceSessionId`, and authoritative assistant replies use real backend speech segments. `AVSpeechSynthesizer` is a clearly labelled on-device fallback when backend speech fails; the actual backend prerequisite remains visible. Call mute/settings/end are explicit current-revision/nonced requests. Calls remain accessible from the menu when navigating elsewhere. Unknown sends are fenced from another send; inspect backend entries/runs rather than automatically replaying. Voice preview calls the fixed backend Bot sample endpoint without creating work. Persisted voice memos remain shared transcript cards and play their authorized actual audio, not synthetic placeholder files.

## Notifications and launch

Launch restores a saved Keychain-backed account, registers this Mac, and publishes viewed-room foreground presence with a 20-second refresh. Explicit notification enablement asks macOS permission and registers APNs. Existing notification snapshots establish a baseline, rather than alerting on historical inbox contents. Hidden Bots, account preferences and the exact active viewed room suppress local delivery; approvals retain individual IDs and informational results coalesce by room. Notification taps and `lemonbot://` URLs use the shared authorized token-free resource router and never resolve gates.

Both the macOS APNs entitlement and `LemonBotAPNSEnvironment` use the project’s `APS_ENVIRONMENT`: development in Debug, production in Release. The registration body maps development to the backend’s `sandbox` spelling. The backend must allowlist topic `org.lemonbot.mac` and configure its real APNs token-auth key/team/topic; unsigned CI builds cannot register push. Local notifications do not require APNs. The App Group is `group.org.lemonbot.shared`. The sandbox grants outbound network, explicit microphone/Speech and user-selected read-only files; no screen/Accessibility/full-disk entitlement is requested.

## Integration checks (parent-owned)

Generate the lead-owned XcodeGen project and build the LemonBotMac scheme with `CODE_SIGNING_ALLOWED=NO` for CI. On a signed Mac, exercise shortcut conflicts/press-release during permission dialogs, denied/no-input Speech, draft preservation across conversations/accounts, actual backend voice preview/transcription/TTS and fallback, active-call mute/end, explicit Services/file import, foreground same-room suppression versus another room, and revoked/foreign-workspace deep links. This slice did not run builds, tests, lint, formatting, XcodeGen, permission prompts or provider probes.

## Changelog

- Added native workspace entry, menu-bar integration, opt-in single companion, Carbon global summon/PTT, review-only Speech dictation, backend voice-session loop and voice preview, explicit Services/file sharing, device/account lifecycle and privacy-bounded notifications/deep links.
- Added CoreImage one-use phone QR and exact-device approval/denial with read-only reconciliation; startup restores the last saved account and foreground reconnect retains offline credentials.
- Added explicit **Copy one-use pairing link** for the phone's secure paste fallback; copying is user-initiated and places a temporary secret on the system clipboard. QR rendering is privacy-sensitive.
