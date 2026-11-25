# E-Paper NFC (iOS)

SwiftUI app for the Good Display **NFC-D1-0154** 1.54" battery-free NFC e-paper board
(Fudan FMSH ESL chip). Pick photo → crop/zoom → brightness/contrast → dithered B/W or
B/W/R/Y preview → write over NFC. The phone's NFC field powers the board, including the refresh.

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
1. Tap **Read tag info** and hold the top of the iPhone on the board. The app reads the
   board's configured panel (size, resolution, colours) and sets Colours/Resolution to match.
2. Choose a photo, adjust.
3. Tap **Write to e-paper** and keep the phone still on the board until "Done ✓"
   (B/W ≈ a few seconds, 3-colour panels take longer). With "Match tag's screen type" on,
   the app re-checks the board's config before every write.

## Troubleshooting
- 6982 → enable "Verify PIN first" (default PIN 1122334455).
- 68C6 → refresh/reset failed; image upload may have completed, but the panel did not reset.
  Check the FPC cable and confirm the screen-specific `DB` driver flow is installed. A custom
  `F0` panel needs that initialization flow; `DA` screen type settings alone do not install it.
  The app matches the reported 304×152 geometry for image packing, but cannot create the
  screen-specific driver data. 68CA → low field power: hold the phone still, centred.
- Image inverted → Invert. Rotated/mirrored → Panel rotation / Mirror.
- Garbage / nothing on screen and Read tag info shows the wrong standard panel → enable
  "Send screen config (DA)", pick the right Colours + Resolution, leave the driver byte blank
  to keep the tag's (or enter the one from Good Display), write once. Then turn it off again.
  Do not use this option for a custom 304×152 panel; its resolution has no standard `DA` code.
- Nothing works in NDEF mode → turn off "NDEF-wrapped commands" to try raw APDUs.
- Every tag error is decoded in the log (manual Appendix A).

## Protocol (from the manual)
- Config: `00 D1 00 00 00` → TLV, tag `A0` = driver, size|pixels (`12` = 1.54" 200×200,
  `02` = 152×152), colour (`20` B/W, `30` B/W/R, `31` B/W/Y), X(2), Y(2).
- Screen type: `F0 DA 00 00 03 <driver> <size> <colour>`, colour params `F0 DA 00 01 …`
  (`120030` B/W, `23003048` B/W/R, `23003068` B/W/Y).
- Upload: `F0 D2 <index> <packet#> <len> <≤250 bytes>`, 1 bpp row-major MSB first —
  plane 1 (1 = white) at index 0, colour plane (1 = red/yellow) at index 1.
- Refresh: `F0 D4 01 80 00` (100 ms power-on delay, return immediately) then poll
  `F0 DE 00 00 01` until `00`.
- iOS transport (section 6): each APDU is written into NDEF file E104 as a mime record
  (type `e`), writing the NDEF length triggers it, the result (data + SW) is read back.
  Commands refused inside NDEF (`6D00`) are automatically retried as raw APDUs.
