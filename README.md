# E-Paper NFC (iOS)

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
Option B – manual: New Xcode project (iOS App, SwiftUI, name EPaperNFC) → replace/add the 5 .swift files →
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
- 68C6 → refresh/reset failed; check the FPC cable. 68CA → low field power: hold the phone still, centred.
- Rotated / mirrored → Advanced → Panel orientation.
- Yellow and red swapped → swap the last two entries of `Panel.palette` in `ImageProcessor.swift`.
- Nothing works in NDEF mode → Advanced → turn off "NDEF-wrapped commands" to try raw APDUs.
- Every tag error is decoded in the log (manual Appendix A).

## Protocol (from the manual)
- Config: `00 D1 00 00 00` → TLV, tag `A0` = driver, size|pixels, colour, X(2), Y(2).
  4-colour panels report X in bits at 2 bpp, so a 152×152 panel reads as 304×152.
- Upload: `F0 D2 <index> <packet#> <len> <≤250 bytes>`, one 2-bpp plane at index 0,
  row-major, 4 pixels per byte, first pixel in bits 7-6 (00 black, 01 white, 10 yellow, 11 red).
  152×152 → 5776 bytes → 24 packets.
- Refresh: `F0 D4 01 80 00` (100 ms power-on delay, return immediately) then poll
  `F0 DE 00 00 01` until `00`.
- iOS transport (section 6): each APDU is written into NDEF file E104 as a mime record
  (type `e`), writing the NDEF length triggers it, the result (data + SW) is read back.
  Commands refused inside NDEF (`6D00`) are automatically retried as raw APDUs.
