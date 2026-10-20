# Stampede

A native Swift menu bar utility that keeps your last 10 or 20 text copies, encrypted locally across restarts.

Select an older entry from the clipboard menu to move it to the top and make it the active clipboard. Paste with **⌘V**, or your existing paste mapping. A later normal copy always becomes active. Selecting history does not automatically type into another app.

## Build and run

Requires macOS 14 or later and Xcode with Swift 6 or later. No third-party dependencies.

```sh
swift test
./scripts/build-app.sh
open build/Stampede.app
```

The `build/` folder contains the single runnable `Stampede.app`. Keep local Xcode verification scratch output under `.build/` and remove its generated app after verification to avoid duplicate app-search results.

Alternatively, open `Stampede.xcodeproj`, select the **Stampede** scheme, and Run. The Xcode project compiles the same sources as the Swift package. After adding source files, regenerate the project with `python3 scripts/generate-xcode-project.py`.

For a stable local installation, quit any running copy, then run:

```sh
./scripts/install-local.sh
```

This builds and installs to `~/Applications/Stampede.app` without replacing an existing installation. To update an existing copy, quit it and replace it deliberately after keeping a backup. Do not alternate running builds from multiple locations against the same saved history.

The app uses a menu bar icon and has no ordinary Dock window. First launch explains storage and lets you enable history and launch at login. Open the clipboard menu for Settings, Pause/Resume, the 10/20 limit, Clear Clipboard, and Quit.

On recent macOS versions, continuous capture requires **Always Allow** clipboard access in **System Settings → Privacy & Security → Paste from Other Apps**. Use **Check Clipboard Access** in Settings to see the current permission and a timestamped result. It initiates one foreground read only when permission is undecided or set to Ask Each Time; allowed access needs no dialog. Checking never captures or promotes an entry and does not resume paused capture. **Open System Settings…** opens Settings so you can search for clipboard/paste permissions when access is blocked. Background polling never repeatedly requests permission. Login-item registration may require approval under **System Settings → General → Login Items**; Settings reports the actual system registration state.

## History and restart behavior

- History is encrypted with CryptoKit AES-GCM in `~/Library/Application Support/com.alanwychen.rotarystamp/history.enc`.
- The encryption key lives in your local macOS Keychain, not in the history file, preferences, or this repository.
- A save happens shortly after a copy or selection. Check that the menu reports **History saved locally · encrypted** before testing a restart. Pending changes can be lost if the process is forcibly terminated before saving.
- Startup restores the list without replacing the system clipboard. Click any saved entry to activate it again.
- Capture pause and history capacity persist. Pausing does not delete existing entries.
- **Clear Clipboard** clears the current Mac clipboard and Stampede’s in-memory and saved history, after confirmation. It does not erase items already pasted, backed up, or stored on other devices.
- **Pause Capture** only stops adding new copies to Stampede. Normal copy/paste and Universal Clipboard continue working; existing saved items remain selectable.
- If history cannot be opened, a popup offers **Try Again** and **Reset**. Try Again retries loading and can request foreground Keychain authorization. Reset permanently replaces saved history with an empty encrypted snapshot, recreating a missing key if necessary. Reset leaves the current Mac clipboard unchanged. If Keychain is locked or access is denied, reset reports the failure instead of silently discarding the old file.
- Clipboard text, previews, and content-derived identifiers are not logged. Marked concealed, transient, and generated content is excluded. Unmarked passwords can still be captured.
- Text is preserved exactly, up to 1 MiB per entry. Images, files, and multi-item copies are not stored; their normal paste behavior remains intact.

The local build is ad-hoc signed and is not sandboxed or notarized. A stable Developer ID signing identity is recommended before relying on it long term: rebuilding an ad-hoc executable can change Keychain trust. A missing or inaccessible key never causes the existing encrypted history to be silently replaced. Set `CODE_SIGN_IDENTITY` when building with an available signing identity. Do not delete the Keychain item if you need to recover saved history.

## iPad and Universal Clipboard

Ordinary Mac copies and explicitly selected history entries use the general pasteboard, preserving Apple's Universal Clipboard path. Copy on iPad and paste on Mac normally; eligible text enters Mac history when the Mac exposes a readable payload to Stampede. Capture never republishes observed remote text.

Devices must be nearby, use the same Apple Account, and have Wi-Fi, Bluetooth, and Handoff on. Apple controls transfer timing and expiration. The full history stays on the Mac; select a saved entry to make it available for a new cross-device paste. Stampede does not poll or control the iPad directly. [Apple's Universal Clipboard guide](https://support.apple.com/en-us/102430)

## Icon artwork

The app and menu bar share native vector stacked-clipboard artwork based on the supplied reference in `Sources/Stampede/StampIcon.swift`. The app icon is black on a white rounded tile; the transparent menu bar template adapts to system appearance. Regenerate the bundled icon with `./scripts/generate-icon.sh` before building after artwork changes. Generated icon sizes stay under `.build/`.

## Verification

```sh
swift test
./scripts/build-app.sh
build/Stampede.app/Contents/MacOS/Stampede --self-test
build/Stampede.app/Contents/MacOS/Stampede --keychain-self-test
open -n -a "$PWD/build/Stampede.app" --args --preview
```

`--keychain-self-test` creates and removes one disposable test key under a unique service identifier, without touching your history key. `--self-test` uses a private pasteboard so it does not inspect or replace your clipboard. `--preview` shows three sample entries without reading/writing the system clipboard, saving history, or registering login items. Quit the preview before running the real app.

Automated coverage includes history ordering and limits, clipboard access checks, encrypted persistence, missing/corrupted history recovery, and clearing. Real-device validation of clipboard permissions, login startup, and Mac ↔ iPad behavior remains separate from these tests.
