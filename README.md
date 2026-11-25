# PIKO Studio (iOS)

SwiftUI app for the Good Display **NFC-D1-0154** 1.54" battery-free NFC e-paper board
(Fudan FMSH ESL chip) with a **152×152 Black / White / Yellow / Red** panel.
Pick photo → adjust → dithered 4-colour preview → write over NFC. The phone's NFC field
powers the board, including the refresh.

## Build
Needs a Mac with Xcode 15+, an iPhone 7 or later (iOS 16+), and an Apple Developer account
(paid program for the NFC Tag Reading capability).

Option A – XcodeGen:
```
brew install xcodegen
cd EPaperNFC && xcodegen
open EPaperNFC.xcodeproj
```
Option B – manual: New Xcode project (iOS App, SwiftUI, name EPaperNFC) → replace/add the 5 .swift files and
`Assets.xcassets` (app icon + logo) →
Signing & Capabilities → + Near Field Communication Tag Reading →
add `NFCReaderUsageDescription` and the `select-identifiers` array from `EPaperNFC/Info.plist`.

Set your Team under Signing, run on the phone (NFC does not work in the Simulator).

## Use
1. Tap the preview to choose a photo.
2. **Adjust** → brightness, contrast, zoom, dithering.
3. **Update Tag** → hold the top of the iPhone on the board and keep still until "Done ✓".
4. **Advanced** → panel rotation / mirror, Read tag info, NDEF mode, PIN, log.

## Troubleshooting
- 6982 → Advanced → enable "Verify PIN first" (default PIN 1122334455).
- 68C6 → screen reset failed or panel not detected; check the FPC cable and keep Advanced → "Check panel before refresh" off. 68CA → low field power: hold the phone still, centred.
- Rotated / mirrored → Advanced → Panel orientation.
- Wrong colours → Advanced → Read tag info shows the colour codes used. If the tag stores none and yellow/red are swapped, set `Panel.defaultCodes` to `[0, 1, 3, 2]` in `ImageProcessor.swift`.
- Writing fails right after "Using direct mode" → Advanced → turn on "Always use iOS NDEF mode".
- Speed: the log shows upload and refresh times. Direct mode uploads in about 1 s; most of the
  total is the 4-colour panel's own refresh.
- Every tag error is decoded in the log (manual Appendix A).

## Protocol (from the manual)
- Config: `00 D1 00 00 00` → TLV, tag `A0` = driver, size|pixels, colour, X(2), Y(2).
  4-colour panels report X in bits at 2 bpp, so a 152×152 panel reads as 304×152.
- Upload: `F0 D2 <index> <packet#> <len> <≤250 bytes>`, one 2-bpp plane at index 0,
  row-major, 4 pixels per byte, first pixel in bits 7-6 (00 black, 01 white, 10 yellow, 11 red).
  152×152 → 5776 bytes → 24 packets.
- Refresh: `F0 D4 81 80 00` (skip screen check, 100 ms power-on delay, return immediately) then poll
  `F0 DE 00 00 01` until `00`.
- Transport: the first command (`D1`) is tried as a direct APDU. If the tag answers `9000`, all
  commands go direct (1 NFC exchange each). Otherwise, or if a command is refused with
  `6D00`/`6E00`, the app switches to the iOS NDEF transport (section 6): each APDU is written into
  NDEF file E104 as a mime record (type `e`), writing the NDEF length triggers it, and NLEN plus
  the result (data + SW) is read back in one read. Commands refused inside NDEF (`6D00`) are
  retried as raw APDUs.
