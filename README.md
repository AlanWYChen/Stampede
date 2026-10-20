<img src="assets/icon.png" width="96" height="96" alt="Stampede icon">

# Stampede

**Your recent copies, one menu away.**

Stampede is a native macOS menu bar app that remembers your last **10 or 20 text copies**, saves them encrypted across restarts, and lets you choose what to paste next.

[![macOS checks](https://github.com/AlanWYChen/Stampede/actions/workflows/ci.yml/badge.svg)](https://github.com/AlanWYChen/Stampede/actions/workflows/ci.yml)

## Features

- **Clipboard history:** select an older entry to move it to the top and make it the active clipboard.
- **Normal paste:** use **⌘V** or your existing paste mapping. A new copy always becomes active; pasting does not consume history.
- **Persistent storage:** AES-256-GCM encryption with a randomly generated key stored in macOS Keychain.
- **Universal Clipboard:** keep copying and pasting between your Mac and nearby Apple devices.
- **Ready at login:** enable automatic launch during setup; manage it later in Settings.
- **Simple controls:** pause capture, choose your history limit, clear the clipboard, or recover unreadable history.

Built with Swift, AppKit, and SwiftUI. No third-party package dependencies or Stampede account required.

## Get started

Stampede currently ships as source. There is no packaged release installer yet.

**Requirements:** macOS 14 or later, plus a full Xcode installation with Swift 6 and the macOS 15.4 SDK or later to build.

```sh
git clone https://github.com/AlanWYChen/Stampede.git
cd Stampede
./scripts/install-local.sh
```

The script builds `Stampede.app`, installs it in `~/Applications`, and opens it. It refuses to overwrite an existing installation.

1. Choose **Enable History & Launch at Login** on the welcome screen.
2. Click the clipboard icon in the menu bar to open your history. Stampede has no ordinary Dock window.
3. Copy some text, select any saved entry, and paste as usual.

If capture needs permission, open **Settings → Check Clipboard Access**. The result explains the current state. Use **Open System Settings…** to review clipboard/paste permissions when needed. Launch at login may also need approval in macOS Login Items settings.

### Build without installing

```sh
./scripts/build-app.sh
open build/Stampede.app
```

You can also open `Stampede.xcodeproj` and run the **Stampede** scheme. Use one copy of the app at a time.

### Update a local installation

Quit Stampede, update your checkout, and rebuild:

```sh
git pull --ff-only
./scripts/build-app.sh
```

Replace `~/Applications/Stampede.app` with the rebuilt `build/Stampede.app`, then reopen it. Saved history lives separately from the app bundle. Local builds are ad-hoc signed; rebuilding can cause macOS to request Keychain authorization again. You can build with your own signing identity using `CODE_SIGN_IDENTITY="Your signing identity" ./scripts/build-app.sh`.

## How it works

Copy `Alpha`, `Bravo`, then `Charlie`. Your history shows `Charlie → Bravo → Alpha`.

Select `Alpha`: history becomes `Alpha → Charlie → Bravo`, and your next paste inserts `Alpha`. Copy `Delta` afterward, and `Delta` becomes the active item.

| Control | Behavior |
| --- | --- |
| **Select an entry** | Makes that text the active system clipboard. You paste it manually. |
| **Pause Capture** | Stops saving new copies. Normal copy/paste and Universal Clipboard keep working; existing entries remain selectable. |
| **Clear Clipboard** | After confirmation, clears the current Mac clipboard and Stampede’s saved history. |
| **Try Again** | Retries opening unreadable history or accessing its encryption key. |
| **Reset** | Starts an empty saved history and recreates a missing key if needed. Leaves the current Mac clipboard unchanged. |

After a restart, Stampede restores your history list **without overwriting the current clipboard**. Select a saved entry when you want to use it again. Pause state and history capacity also persist.

## Privacy and storage

Stampede keeps history locally. It encrypts the entire saved snapshot using **CryptoKit AES-256-GCM**, with a fresh random nonce for each save. Its random 256-bit key is stored separately in Keychain, with iCloud Keychain synchronization disabled.

- Clipboard text and previews are not logged.
- Content marked concealed, transient, or automatically generated is excluded.
- **Unmarked passwords and other sensitive text can still be captured.** Pause capture or clear the clipboard when needed.
- Encryption protects the saved file; history remains readable in memory and in the app while running.
- Saves happen shortly after a copy. Unsaved changes can be lost if the app is forcibly terminated before a save completes.
- If history or its key cannot be read, Stampede reports the error rather than silently replacing the file. If the key is permanently lost, the old history cannot be decrypted.

<details>
<summary>Storage location and Keychain entry</summary>

History file:

```text
~/Library/Application Support/com.alanwychen.rotarystamp/history.enc
```

- Service: `com.alanwychen.rotarystamp.history`
- Account: `history-key-v1`

These identifiers are retained for compatibility with early installations. Clearing or resetting history does not erase copies in backups, items already pasted elsewhere, or data stored on other devices.

</details>

### Mac, iPad, and iPhone

Stampede uses the normal system clipboard, so ordinary copies and explicitly selected history entries remain eligible for Apple’s Universal Clipboard. Readable text arriving from another device can also enter the Mac’s history while capture is enabled.

Devices must be nearby, signed in to the same Apple Account, and have Wi-Fi, Bluetooth, and Handoff enabled. Apple controls delivery and expiration. The **full history stays on the Mac**; select an old entry to make it available for another cross-device paste. [Apple’s Universal Clipboard guide](https://support.apple.com/en-us/102430)

## Current limitations

- **Text only:** images, files, and multi-item copies are not saved. Their normal system paste behavior is unaffected.
- **Bounded history:** 10 or 20 entries, with a maximum of 1 MiB of UTF-8 text per entry.
- **Polling:** very rapid copies between checks can be missed. Stampede cannot reconstruct copies made while it was closed or the Mac was asleep.
- **Local builds:** ad-hoc signed by default and not sandboxed. No notarized installer or automatic updater is provided.

## Development

```sh
swift test
./scripts/build-app.sh
build/Stampede.app/Contents/MacOS/Stampede --self-test
build/Stampede.app/Contents/MacOS/Stampede --keychain-self-test
```

`--self-test` uses a private pasteboard without inspecting or changing your clipboard. `--keychain-self-test` creates and removes a disposable test key without touching the history key. Automated checks cover history ordering, limits, access checks, persistence, recovery, and clearing; CI also builds the native Xcode project.

For a sample-data preview that does not access your clipboard, save history, or register login items:

```sh
open -n -a "$PWD/build/Stampede.app" --args --preview
```

Quit the preview before running the real app. Permission dialogs, automatic launch after reboot, and cross-device delivery still need testing in a real user session.

| Location | Purpose |
| --- | --- |
| `Sources/Stampede/` | Menu bar app, Settings, and system clipboard adapter |
| `Sources/StampedeCore/` | History model, monitoring, and encrypted storage |
| `Tests/StampedeCoreTests/` | Automated core tests |
| `scripts/` | Build, install, icon generation, and Xcode project generation |

After adding or moving Swift source files, run `python3 scripts/generate-xcode-project.py` to update the checked-in Xcode project. After changing `Sources/Stampede/StampIcon.swift`, run `./scripts/generate-icon.sh` to regenerate the bundled icon and README image. Keep generated build output under the ignored `.build/` and `build/` directories.

## Contributing

[Bug reports](https://github.com/AlanWYChen/Stampede/issues/new) and focused pull requests are welcome. Include your macOS version, steps to reproduce, and expected behavior. Use sample text rather than private clipboard contents in reports.

For code changes, run `swift test` and `./scripts/build-app.sh`, and describe how you verified the change. Add regression coverage for changes to capture, ordering, storage, or recovery.

## License

No license has been selected yet.
