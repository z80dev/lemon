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

Only the original lemon ships with Lemon Bot. Third-party artwork is imported by you; check its license before sharing or redistributing it.

Choose **Import pet…** and select a pet folder, a folder containing pet folders, a `.zip`, or a `pet.json` file. If accessible, the picker starts at `~/.codex/pets`. Selecting a package grants Lemon Bot access only for that import; the validated package is copied into the app’s local pet library.

When selecting `pet.json` alone, macOS also asks you to select its enclosing folder so the sandbox can read the adjacent spritesheet. A grant for the JSON file alone does not grant access to the image.

Alternatively choose **Import from URL…**, paste an **HTTPS** URL to a `.zip` or `pet.json`, then choose **Import**. A remote manifest’s image must be a relative package image, not an arbitrary external URL. Errors appear below the controls; importing never replaces or removes the built-in lemon.

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

For a transparent PNG of the actual live panel (no Screen Recording permission), add `-LBPetCapture <absolute-png-path>` **together with `-LBFixtures`**. It captures the rendered sprite layer and SwiftUI bubble after about 1.5 seconds and keeps running. The capture flag enables the pet even without a forced mood, so `-LBFixtures -LBPetCapture <path>` records the real fixture-derived state. Add `-LBPetHover` for a deterministic hover/detail presentation. Choose a writable path within the sandbox's temporary directory when running the sandboxed app, then copy the PNG to your review directory. These captures are panel-only, not evidence of desktop compositing or click-through.

The `LemonBotSnapshots` scheme’s `PetSnapshotTests/testPetMoods` writes one PNG per mood plus a hover/detail scene. Set `TEST_RUNNER_LB_SNAPSHOT_DIR=/tmp/lb-ux/pet` when invoking `xcodebuild test`.
