# narrative-clip-sync

**Narrative Clip Sync** is a small macOS menu bar app that gets photos off a **Narrative Clip 1** (a.k.a. Memoto) lifelogging camera — no Narrative account, no cloud service. Narrative shut down years ago and its uploader won't work without logging in; this talks to the camera directly over USB.

## Features

- **Auto-sync** when the camera is plugged in, and sets the camera clock to the Mac's time
- **Photos come out ready to use**: rotated upright using the camera's accelerometer data (matching the official app), with the correct local shot time written into EXIF, and named `yyyy-MM-dd HHmmss.jpg`
- **Safe clearing of the camera**: a photo is deleted from the camera only after the copy on the Mac has been verified byte for byte. The default is to ask after each sync
- **Built-in browser**: view photos by day; deleting a photo there also deletes its `.json`/`.snap` sidecar files
- **Import old exports**: brings Narrative Uploader exports into the same library (`narrative-clip-sync import`)
- **`narrative-clip-sync` command-line tool** for scripting

> The interface is available in English and Traditional Chinese and follows your Mac's language. Translations live in `ClipSyncApp/Sources/Localizable.xcstrings`; pull requests adding more languages are welcome.

## Requirements

- macOS 15 Sequoia or later (Apple silicon or Intel)
- Narrative Clip **1** (USB `f0f0:1337`). The Clip 2 is not supported.
- Tested on one camera running firmware 0.23.1. Other Clip 1 firmware versions likely use the same protocol but haven't been tested; please open an issue if yours behaves differently.

## Install

1. Download `NarrativeClipSync.zip` from [Releases](../../releases), unzip it, and move `Narrative Clip Sync.app` to `/Applications`.
2. The app isn't signed with a paid Apple Developer ID, so macOS blocks it the first time. Choose one of these:
   - Try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - In Terminal, run `xattr -dr com.apple.quarantine "/Applications/Narrative Clip Sync.app"`
3. A camera icon appears in the menu bar. Plug in the Clip.

Photos go to `~/Pictures/Narrative Clip/` by default. You can change this in Settings:

```
Narrative Clip/
├── Photos/       rotated JPEGs, named by shot time
└── Metadata/     each photo's .meta.json / .meta.snap, kept in case you need them
```

## Build from source

Requires Xcode 16 or later.

```sh
open ClipSyncApp/NarrativeClipSync.xcodeproj     # then Run
./scripts/build-release.sh              # or: universal Release build → dist/NarrativeClipSync.zip
```

The Xcode project is generated from `ClipSyncApp/project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you change the project settings, edit `project.yml` and run `xcodegen`.

Command-line tool:

```sh
cd ClipKit
swift run narrative-clip-sync info           # camera ID, firmware version, clock
swift run narrative-clip-sync pull           # copy photos to the default library
swift run narrative-clip-sync pull --delete  # …and clear the photos that verified correctly
swift test
```

## Repository layout

| Path | What it is |
|---|---|
| `ClipKit/` | Swift package: USB protocol (IOUSBHost), sync engine, photo library, `narrative-clip-sync` CLI |
| `ClipSyncApp/` | SwiftUI menu bar app |
| `clip1.py` | Minimal Python/pyusb client: the whole protocol in one file |
| `reference/` | Reverse-engineering notes and tools |

## How the camera works

The Clip 1 runs Linux and shows up as a vendor-specific USB device. Commands are vendor control requests, and file data comes back over bulk endpoint `0x81`. The full protocol is documented in [`ClipKit/Sources/ClipKit/ClipDevice.swift`](ClipKit/Sources/ClipKit/ClipDevice.swift) and [`reference/README.md`](reference/README.md).

## Disclaimer

This project is not affiliated with Narrative AB. "Narrative" and "Narrative Clip" are trademarks of their owners. The protocol was worked out for interoperability with hardware the author owns. Use at your own risk: keep backups, and use the camera-clearing feature carefully.

## License

[MIT](LICENSE)
