# Narrative Uploader reverse-engineering notes

The Clip 1 protocol implemented in ClipKit was worked out from **Narrative Uploader 2.5.3** (`com.narrative.osx-uploader`, x86_64, 2014–2016), the official Mac app.

| File | What it is |
|---|---|
| `annotate_cfstrings.py` | Parses the Mach-O `__cfstring` section and replaces `otool`'s `bad cfstring ref` placeholders with the actual string contents, which makes the disassembly readable |

The disassembly itself is derived from proprietary software, so it is **not included** in this repository (see `.gitignore`). If you have a copy of Narrative Uploader 2.5.3, you can generate it yourself:

```sh
BIN="Narrative Uploader.app/Contents/MacOS/Narrative Uploader"
otool -tV "$BIN" > raw.txt
python3 annotate_cfstrings.py "$BIN" raw.txt NarrativeUploader-2.5.3-disasm.txt
```

## Finding your way around

Each Objective-C method starts with a `-[Class selector]:` line, so you can find it with grep:

```sh
grep -n '^-\[ClipOneStrategy' NarrativeUploader-2.5.3-disasm.txt
```

| Method | Line (approx.) | Purpose |
|---|---|---|
| `-[ClipOneStrategy init]` | 51434 | Event file name regex, date format, `paramMap` table |
| `-[ClipOneStrategy open:]` | 51949 | Connection sequence: read properties 1/2/4, set the clock (write property 4) and wait for `ACK` |
| `-[ClipOneStrategy paramMap]` | 52593 | Property table (**not yet decoded**; probably camera settings) |
| `-[ClipTwoStrategy open:]` | 60608 | Clip 2 connection sequence (not implemented) |
| `-[CameraV2 updateFirmware:error:]` | 79123 | Firmware update (bRequest `0x10`/`0x11`, **deliberately not implemented**) |
| `-[CameraV2 contentsOfDirectory:fileCount:]` | 80212 | List directory (bRequest `0x09`) |
| `-[CameraV2 readFile:]` | 80371 | Read file (bRequest `0x02`) |

To decode the call arguments, start from `_IOUSBDevRequestMake(req, dirIn, bRequest, wValue, wIndex, data, wLength)`, where `bmRequestType = (dirIn << 7) | 0x40`.

## Decoded and implemented in ClipKit

The full description is in the header comment of `ClipKit/Sources/ClipKit/ClipDevice.swift`. A minimal Python version is in `clip1.py`.

- Get property (`0x04`), set property (`0x05`), list directory (`0x09`), read file (`0x02`), delete file (`0x03`)
- Orientation: with θ = atan2(y, −x) from the accelerometer reading in `meta.json`, the quadrant gives EXIF orientation 1 / 6 / 3 / 8. This was derived from 561 photos exported by the official app, and matches all of them
- Times in event file names are UTC
