<img src="assets/icon.png" width="96" height="96" alt="Stampede icon">

# Stampede

**Your recent copies, one menu away.**

Stampede is a native macOS menu bar app that remembers your last **5, 10, or 20 text and image copies**, saves them encrypted across restarts, and lets you choose what to paste next.

[![macOS checks](https://github.com/AlanWYChen/Stampede/actions/workflows/ci.yml/badge.svg)](https://github.com/AlanWYChen/Stampede/actions/workflows/ci.yml)

## Features

- **Photo copies:** recognize images by a small thumbnail and dimensions; select one to restore its full-resolution original for normal paste.
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
3. Copy text or an image, select any saved entry, and paste as usual.

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
| **Select an entry** | Makes that text or full-resolution image the active system clipboard. You paste it manually. |
| **Settings → History Limit** | Keeps the most recent 5, 10, or 20 entries. Reducing the limit removes older entries. |
| **Pause Capture** | Stops saving new copies. Normal copy/paste and Universal Clipboard keep working; existing entries remain selectable. |
| **Clear Clipboard** | After confirmation, clears the current Mac clipboard and Stampede’s saved history. |
| **Try Again** | Retries opening unreadable history or accessing its encryption key. |
| **Reset** | Starts an empty saved history and recreates a missing key if needed. Leaves the current Mac clipboard unchanged. |

Images appear as a thumbnail plus a label such as **Image · 1920 × 1080 · Safari · example.com**. The app name is a best-effort indication of the foreground app when the copy was observed, not verified provenance (especially for remote or pre-launch copies). The domain appears only if the clipboard item supplies an HTTP(S) URL; it may refer to an image host rather than the page you visited. Stampede does not inspect browser tabs, fetch websites, or generate image descriptions. Long source labels are shortened.

After a restart, Stampede restores your history list **without overwriting the current clipboard**. Select a saved entry when you want to use it again. Pause state and history capacity also persist.

## Privacy and storage

Stampede keeps history locally. It encrypts the history manifest and separate image blobs using **CryptoKit AES-256-GCM**, with a fresh random nonce for each save. Its random 256-bit key is stored separately in Keychain, with iCloud Keychain synchronization disabled.

After a successful Keychain lookup, the running app caches the key in memory for history saves, reloads, and resets. Failed lookups can be retried. Restarting the app requires retrieving the key from Keychain again.

- Clipboard text, images, source labels, and previews are not logged.
- Content marked concealed, transient, or automatically generated is excluded.
- **Unmarked passwords and other sensitive text can still be captured.** Pause capture or clear the clipboard when needed.
- Encryption protects the saved file; history remains readable in memory and in the app while running.
- Saves happen shortly after a copy. Unsaved changes can be lost if the app is forcibly terminated before a save completes.
- If history or its key cannot be read, Stampede reports the error rather than silently replacing the file. If the key is permanently lost, the old history cannot be decrypted.

<details>
<summary>Storage location and Keychain entry</summary>

History manifest (including text and image metadata):

```text
~/Library/Application Support/com.alanwychen.rotarystamp/history.enc
```

Image originals are stored beside it in `images/<random-uuid>.enc`, individually encrypted with the same Keychain key and authenticated with their blob ID and format. Reordering history does not re-encrypt image bytes. Thumbnails are generated in memory. Clear/reset remove owned image blobs after committing empty history; deletion failures are reported through storage status and can be retried. Missing or damaged image blobs disable only their affected menu entries. Older text-only history upgrades on the next successful save; older app binaries cannot read the new format.

- Service: `com.alanwychen.rotarystamp.history`
- Account: `history-key-v1`

These identifiers are retained for compatibility with early installations. Clearing or resetting history does not erase copies in backups, items already pasted elsewhere, or data stored on other devices.

To investigate startup authorization prompts, filter the Xcode console for `Keychain lookup` or run this before launching Stampede:

```sh
log stream --style compact --predicate 'subsystem == "com.alanwychen.rotarystamp" AND category == "HistoryKeychain"'
```

Each lookup logs a begin/end pair with a request ID and numeric status (`0` means success). These logs contain operation metadata only, without key material or clipboard contents. Two dialogs between the same begin/end pair indicate authorization within one system lookup; multiple pairs indicate separate app lookups. Compare process IDs as well when checking for multiple running builds. The dialog wording alone does not establish the cause. Local ad-hoc rebuilds can require authorization again; use a stable signing identity when testing persistent trust.

</details>

### Mac, iPad, and iPhone

Stampede uses the normal system clipboard, so ordinary copies and explicitly selected history entries remain eligible for Apple’s Universal Clipboard. Readable text arriving from another device can also enter the Mac’s history while capture is enabled.

Devices must be nearby, signed in to the same Apple Account, and have Wi-Fi, Bluetooth, and Handoff enabled. Apple controls delivery and expiration. The **full history stays on the Mac**; select an old entry to make it available for another cross-device paste. [Apple’s Universal Clipboard guide](https://support.apple.com/en-us/102430)

## Current limitations

- **Images:** single-frame PNG, TIFF, JPEG, and HEIC, plus static and animated GIF and WebP clipboard data are supported. GIF, then WebP, then PNG, TIFF, JPEG, and HEIC is preferred when multiple formats are offered, preserving animation over still-image fallbacks. Original bytes, including all animation frames, are preserved for paste; history shows a still thumbnail of the first frame. Animations are limited to 500 frames, with the image dimension limits applied to every frame. File-reference-only copies (including Finder copies), file promises, PDFs, multi-frame images in other formats, and multi-item copies are excluded. When an app such as WeChat supplies both image bytes and a file reference, Stampede saves the supplied image without opening the referenced file. Their normal paste behavior is unaffected.
- **Bounded history:** 5, 10, or 20 mixed entries; 1 MiB of UTF-8 text per entry; 20 MiB, 16 megapixels, and 8,192 pixels per edge for an image. A 100 MiB total payload budget can evict older entries before the count limit is reached. Oversized images leave existing history intact.
- **Polling:** very rapid copies between checks can be missed. Stampede cannot reconstruct copies made while it was closed or the Mac was asleep.
- **Local builds:** ad-hoc signed by default and not sandboxed. No notarized installer or automatic updater is provided.

## Development

```sh
swift test
./scripts/build-app.sh
build/Stampede.app/Contents/MacOS/Stampede --self-test
build/Stampede.app/Contents/MacOS/Stampede --keychain-self-test
```

`--self-test` uses a private pasteboard without inspecting or changing your clipboard. `--keychain-self-test` creates and removes a disposable test key without touching the history key. Automated checks cover mixed history ordering, image validation, limits, access checks, encrypted image persistence, legacy migration, recovery, and clearing; CI also builds the native Xcode project.

For a sample-data preview that does not access your clipboard, save history, or register login items:

```sh
open -n -a "$PWD/build/Stampede.app" --args --preview
```

Quit the preview before running the real app. Permission dialogs, automatic launch after reboot, and cross-device delivery still need testing in a real user session. Image support has synthetic PNG/TIFF/JPEG/HEIC/GIF/WebP private-pasteboard coverage (including animated GIF/WebP); actual Safari/Chrome, Preview, Notes, Messages, image-editor, and iPad/iPhone compatibility and color-profile appearance still require manual verification.

Image validation/downsampling and encrypted disk work run off the main actor. Validated encoded originals stay in memory (up to the 100 MiB retention budget), so selection does not wait for disk I/O or overwrite a newer copy after a delayed load. Queued image candidates have a separate combined 20 MiB limit; thumbnails have a 128-pixel longest edge. These are payload limits, not absolute peak RAM/disk guarantees: pasteboard providers may allocate data before its size can be checked, and decoders/encryption/atomic replacement require additional memory and disk space.

| Location | Purpose |
| --- | --- |
| `src/Stampede/` | Menu bar app, Settings, and system clipboard adapter |
| `src/StampedeCore/` | History model, monitoring, and encrypted storage |
| `Tests/StampedeCoreTests/` | Automated core tests |
| `scripts/` | Build, install, icon generation, and Xcode project generation |

After adding or moving Swift source files, run `python3 scripts/generate-xcode-project.py` to update the checked-in Xcode project. After changing `src/Stampede/StampIcon.swift`, run `./scripts/generate-icon.sh` to regenerate the bundled icon and README image. Keep generated build output under the ignored `.build/` and `build/` directories.

The Xcode navigator mirrors the source, test, resource, and script folders. Run core tests with `swift test`; the Xcode scheme builds and runs the app.

Swift formatting uses four-space indentation and a 120-column target, configured in `.swift-format`. Format source files, tests, and the package manifest with the Xcode toolchain formatter:

```sh
xcrun swift-format format --in-place --recursive src Tests Package.swift scripts/generate-icon.swift
```

## Contributing

[Bug reports](https://github.com/AlanWYChen/Stampede/issues/new) and focused pull requests are welcome. Include your macOS version, steps to reproduce, and expected behavior. Use sample text rather than private clipboard contents in reports.

For code changes, run `swift test` and `./scripts/build-app.sh`, and describe how you verified the change. Add regression coverage for changes to capture, ordering, storage, or recovery.

## License

Licensed under the [MIT License](LICENSE).
