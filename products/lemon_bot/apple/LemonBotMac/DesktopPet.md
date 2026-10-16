# Desktop pet

Lemon Bot can show a small, original pixel lemon above your other windows, including full-screen spaces. It is off by default and works even when you are signed out.

## Show, hide and choose a pet

Choose **Show Desktop Pet** or **Hide Desktop Pet** from Lemon Bot’s menu-bar menu. You can also use **Settings → This Mac → Desktop pet → Show desktop pet**, or right-click the pet and choose **Hide Pet**. The settings section saves each change immediately; the other local settings’ Save button is not needed.

Choose a pet and **Small (72 pt)**, **Medium (96 pt)** or **Large (128 pt)**. Medium is the default. The original lemon is always available. If a selected imported pet cannot load, Lemon Bot shows the built-in lemon and explains the error in settings.

## What it shows

The pet reflects the live state already available in Lemon Bot, not activity in other apps. Attention and connection states take priority over active work.

| State | Animation | Persistent bubble |
| --- | --- | --- |
| Signed out | Idle | Sign in to Lemon Bot |
| Offline / sign-in expired | Failed | Offline / Sign in again |
| Needs input | Waiting | Needs approval, Has a question, Needs your input, or a count |
| Recent failed run | Failed | Run failed |
| Working | Active-work row | None; hover for Bot and step |
| Thinking / inspecting | Review row | None; hover for Bot and step |
| Recent completion | One jump, then idle | Done! |
| Ready | Idle, with quiet pauses | None |

The greeting and hover animation is a single wave. Codex V2 pets can look toward a nearby pointer while idle. The system’s Reduce Motion setting or Lemon Bot’s **Reduced motion → On** uses a static first frame instead. Animations and status-expiry timers stop while the pet is hidden or not visible.

## Click, hover and move

- **Hover over the character:** wave once and show the current detail text. Move away to return to the normal bubble.
- **Click the character or bubble:** open the relevant conversation or resource in Lemon Bot; if there is no resource, open the workspace.
- **Drag the character:** move it anywhere. It runs left or right while you drag, then stays within that display’s usable desktop area.
- **Right-click:** open Lemon Bot, open pet settings, or hide the pet.

Transparent parts of the overlay pass mouse events through to the window underneath. Only the visible character pixels and its bubble receive clicks. The pet never becomes the key window and does not take keyboard focus while hovering or dragging.

Position is saved separately for each display, using offsets within its usable desktop area. The default is the main display’s bottom-right corner, with a 24 pt margin. If a saved display disappears or the pet is no longer on a usable desktop, it returns to that default. **Reset position** does the same manually.

## Import Codex pets

Only the original lemon ships with Lemon Bot. Any pet made for the Codex app works: install-ready packages from Codex pet galleries such as [codexpet.xyz](https://codexpet.xyz), [petscodex.com](https://petscodex.com) or [codexpetdb.com](https://codexpetdb.com), or your own `~/.codex/pets` folder. Third-party artwork is imported by you; check its license before sharing or redistributing it.

Choose **Import pet…** and select a pet folder, a folder containing pet folders, a `.zip`, or a `pet.json` file. If accessible, the picker starts at `~/.codex/pets`. Selecting a package grants Lemon Bot access only for that import; the validated package is copied into the app’s local pet library.

When selecting `pet.json` alone, macOS also asks you to select its enclosing folder so the sandbox can read the adjacent spritesheet. A grant for the JSON file alone does not grant access to the image.

Alternatively choose **Import from URL…**, paste an **HTTPS** link to a pet ZIP (including extensionless gallery download links) or a `pet.json`, then choose **Import**. A link that returns a web page instead of a ZIP is rejected. A remote manifest’s image must be a relative package image on the same origin, not an arbitrary external URL. Errors appear below the controls; importing never replaces or removes the built-in lemon.

A pet contains `pet.json` and a static PNG or WebP atlas. Lemon Bot supports Codex V1 (1536×1872) and V2 (1536×2288), with 192×208 cells in eight columns. The limits are 20 MiB per download or image, 64 KiB per manifest, 32 MiB expanded per ZIP, and 64 ZIP entries. Packages are validated before installation, including archive paths, image type and dimensions. Invalid paths, symlinks and nested archives are rejected. Only the validated manifest and image are installed; additional package files never run. An import error explains the applicable limit.

**Pets are images only; nothing in a pet package runs.** No installer, command or script from a package is launched. Imported pets can be removed with **Remove** and confirmation; the built-in lemon cannot be removed.

## Sounds and privacy

**Play sounds** is off by default. When enabled, entering needs-input, done or failed plays a quiet system cue. Ordinary work, hover and dragging are silent.

Pet preferences belong to this Mac, independently of your Lemon Bot account. The pet only shows status already in the app. It does not read other windows, take screenshots, listen to audio, monitor the clipboard or request Accessibility permission. Mouse movement is used only to route clicks through transparent pixels, handle hovering and direct V2 gaze. Mouse monitors are removed when the pet is hidden. Importing a URL performs the explicit download you requested; the pet does not contact a gallery automatically.

## DEBUG design previews

Build the signed Debug Mac app using the [Apple build guide](../README.md#generate-build-and-launch), with a private derived-data directory. These launch flags are DEBUG-only:

```sh
open -n '/tmp/lemonbot-pet-mac/Build/Products/Debug/Lemon Bot.app' --args \
  -LBFixtures -LBPetPreview working -LBPetPosition 600,400
```

`-LBFixtures` loads the in-memory fixture workspace without real credentials, Keychain or network. Optionally add `-LBFixtureScene <slug>` to select a fixture scenario. `-LBPetPreview <mood>` forces the pet visible with a fixed presentation: `idle`, `thinking`, `working`, `needsInput`, `done`, `failed`, `offline` or `signedOut`. `-LBPetPosition x,y` positions the overlay deterministically in AppKit screen coordinates. Without `-LBPetPreview`, the pet derives its state from the fixture workspace and can be enabled from the menu or settings.

Both fixture and pet-preview launches use volatile pet preferences and a temporary pet library, never the user’s real device preferences or imported pets. Always use `-LBFixtures` for screenshot runs. Quit only the specific preview process you launched; other Lemon Bot instances may be running.

For a transparent PNG of the actual live panel (no Screen Recording permission), add `-LBPetCapture <absolute-png-path>` **together with `-LBFixtures`**. It captures the rendered sprite layer and SwiftUI bubble about three seconds after launch, once the greeting wave has finished, and keeps running. The capture flag enables the pet even without a forced mood, so `-LBFixtures -LBPetCapture <path>` records the real fixture-derived state. Add `-LBPetHover` for a deterministic hover/detail presentation. Choose a writable path within the sandbox's temporary directory when running the sandboxed app, then copy the PNG to your review directory. These captures are panel-only, not evidence of desktop compositing or click-through.

The `LemonBotSnapshots` scheme’s `PetSnapshotTests/testPetMoods` writes one PNG per mood plus a hover/detail scene. Set `TEST_RUNNER_LB_SNAPSHOT_DIR=/tmp/lb-ux/pet` when invoking `xcodebuild test`.

## Testing

### Automated (no GUI)

The decisions behind the overlay live in `LemonBotKit/Sources/LemonBotKit/Pet/` (`PetActivity.swift`, `PetInteraction.swift`) and take plain values, so they run without a window or a desktop session. `MacPetController` feeds them real pointer, screen and status values and applies the answers to the panel. From the `apple` directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path LemonBotKit --filter 'PetInteractionTests|PetActivityTests'
```

| Behaviour | Covered logic | Tests |
| --- | --- | --- |
| Click-through | alpha-mask hit test (`PetAlphaMask`, threshold, edge clamping), sprite/bubble hit regions, hidden bubble, mouse-ignore rule while dragging, gaze range | `PetInteractionTests` |
| Drag | 3 pt threshold, window origin follows the pointer, run-left/right direction, click vs. drag release, display clamp, default corner, per-display offsets | `PetInteractionTests` |
| Click-to-open | status deep link → route, otherwise open the workspace | `PetInteractionTests`, deep-link validation in `PetActivityTests` |
| Live run events | run/notification/transcript state → mood, bubble, link and expiry; mood change → animation, once-only done jump, sound cue, expiry refresh delay | `PetActivityTests`, `PetInteractionTests` |

### Manual checklist (needs a real desktop)

These depend on AppKit windowing, the WindowServer or the live backend and are not automated. Run a Debug or release Mac build signed in to a real backend, with the pet shown. Tick each on any release that touches the pet, `MacPetController` or `MacPetContentView`.

- [ ] **Click-through:** clicking a transparent corner of the pet window reaches the app beneath; clicking an opaque sprite pixel or the bubble does not. Still true after the animation advances to a frame with a different silhouette.
- [ ] **No focus theft:** hovering, clicking and dragging the pet never makes it the key window or moves keyboard focus from the frontmost app.
- [ ] **Drag:** dragging follows the pointer smoothly, plays the run-left/right animation, releases without opening Lemon Bot, and the pet stays on screen. Drag it past each screen edge and Dock; it clamps within the usable area.
- [ ] **Position persistence:** the position survives hide/show and relaunch; with two displays it is remembered per display. Unplug the display it was on: it returns to the main display's bottom-right corner. **Reset position** does the same.
- [ ] **Click-to-open:** with a run needing approval, clicking the pet or bubble opens that conversation. With nothing pending, it opens/focuses the workspace, also from another app, another Space and a full-screen app.
- [ ] **Overlay level:** the pet floats above ordinary windows and appears on every Space and over full-screen apps. It does not appear in Cmd-Tab or Mission Control window cycling.
- [ ] **Hover and gaze:** hover waves once and shows the detail text; moving away restores the bubble. (V2 pets) an idle pet looks toward a nearby pointer.
- [ ] **Context menu:** right-click offers Open Lemon Bot, Pet Settings… and Hide Pet, and each works.
- [ ] **Live events:** against a real backend, start a run that uses a tool, then one that needs approval, one that completes and one that fails. The pet moves thinking → working → needs input → done/failed without refreshing the app, the Done!/Run failed bubbles disappear after about 6 s/60 s, and stopping the backend shows Offline.
- [ ] **Sounds:** with **Play sounds** on, only needs-input, done and failed play a cue; work, hover and dragging are silent.
- [ ] **Visibility cost:** hide the pet, or cover it with a full-screen window; animation and status timers stop (idle CPU near zero in Activity Monitor).
- [ ] **Reduced motion:** toggling System Settings → Accessibility → Display → Reduce motion switches to a static frame without relaunching.
- [ ] **Accessibility:** VoiceOver reads the pet as a button with the current status, and its press action opens Lemon Bot.

## Editing and sharing the lemon

The built-in lemon is original Lemon Bot artwork, dedicated to the public domain under [CC0 1.0](../LemonBotKit/Sources/LemonBotKit/Resources/Pets/lemon/LICENSE): copy, modify, redistribute or submit it anywhere, no attribution required. Its generator, `scripts/generate_lemon_pet.py` (Python 3 + Pillow; deterministic), is CC0 too. The rest of Lemon remains MIT licensed. Codex's `pet.json` has no license or author field, so the license travels as a `LICENSE` file inside the package.

From the `apple` directory, run `python3 scripts/generate_lemon_pet.py --output /tmp/lemon-pet --check --zip /tmp/lemon-pet/lemon.codex-pet.zip`, review `/tmp/lemon-pet/qa/contact-sheet.png` and the per-row GIFs, then copy `/tmp/lemon-pet/lemon/{pet.json,spritesheet.png,LICENSE}` to `LemonBotKit/Sources/LemonBotKit/Resources/Pets/lemon/`. The package is a standard Codex V2 pet, so it also works in the Codex app: unzip `lemon.codex-pet.zip` into `~/.codex/pets/lemon/`. That reproducible ZIP holds `pet.json`, `spritesheet.png` and `LICENSE` at its root, the layout community galleries accept; a gallery that wants only the manifest and image can drop `LICENSE`, since CC0 requires no notice.
