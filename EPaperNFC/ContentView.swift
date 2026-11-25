import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var nfc = NFCManager()
    @State private var pickerItem: PhotosPickerItem?
    @State private var source: UIImage?
    @State private var settings = ImageSettings()
    @State private var processed: Processed?
    @State private var tagInfo: String?

    // Advanced
    @State private var wrapNDEF = true
    @State private var matchTag = true
    @State private var usePIN = false
    @State private var pin = "1122334455"
    @State private var sendConfig = false
    @State private var manufacturer = ""
    @State private var horizontalScan = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        Rectangle().fill(Color(white: 0.92))
                        if let p = processed {
                            Image(uiImage: p.preview).resizable().interpolation(.none).scaledToFit()
                        } else {
                            Text("Pick an image").foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .listRowInsets(EdgeInsets())

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose photo", systemImage: "photo")
                    }
                }

                Section("Adjust") {
                    slider("Brightness", $settings.brightness, -0.5...0.5)
                    slider("Contrast", $settings.contrast, 0.5...2.0)
                    slider("Zoom", $settings.zoom, 1...3)
                    Toggle("Dithering", isOn: $settings.dither)
                    if settings.color == .bw { Toggle("Invert", isOn: $settings.invert) }
                    Button("Reset adjustments") {
                        settings.brightness = 0; settings.contrast = 1; settings.zoom = 1
                    }
                }

                Section {
                    Picker("Colours", selection: $settings.color) {
                        ForEach(EPaperColor.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Panel rotation", selection: $settings.rotation) {
                        Text("0°").tag(0); Text("90°").tag(1); Text("180°").tag(2); Text("270°").tag(3)
                    }
                    Toggle("Mirror", isOn: $settings.mirror)
                    Toggle("Match tag's screen type", isOn: $matchTag)
                } header: {
                    Text("Display")
                } footer: {
                    if let tagInfo { Text("Tag: \(tagInfo)") }
                }

                Section {
                    Button { write() } label: {
                        Label("Write to e-paper", systemImage: "wave.3.right").frame(maxWidth: .infinity)
                    }
                    .disabled(source == nil || nfc.busy)
                    Button("Read tag info") { readInfo() }.disabled(nfc.busy)
                }

                Section("Advanced") {
                    Toggle("NDEF-wrapped commands (iOS mode)", isOn: $wrapNDEF)
                    Toggle("Verify PIN first", isOn: $usePIN)
                    if usePIN { TextField("PIN (hex)", text: $pin).font(.body.monospaced()) }
                    Toggle("Send screen config (DA)", isOn: $sendConfig)
                    if sendConfig {
                        TextField("Driver byte (hex, blank = keep tag's)", text: $manufacturer)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Toggle("Horizontal scan (DA 0101)", isOn: $horizontalScan)
                        Text("Writes Colours + Resolution above to the tag. Only needed once, for an unconfigured "
                             + "or wrongly configured board. Use “Read tag info” first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Log") {
                    ForEach(Array(nfc.log.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                    if !nfc.log.isEmpty { Button("Clear log") { nfc.log.removeAll() } }
                }
            }
            .navigationTitle("E-Paper NFC")
        }
        .onChange(of: pickerItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    source = img
                    update()
                }
            }
        }
        .onChange(of: settings) { _ in update() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }

    private func update() {
        guard let source else { return }
        processed = ImageProcessor.render(source, settings)
    }

    /// Copy the tag's configured panel type into the UI (and the driver byte field).
    private func apply(_ cfg: TagConfig) async {
        await MainActor.run {
            tagInfo = cfg.summary
            if manufacturer.isEmpty, let m = cfg.manufacturer { manufacturer = String(format: "%02X", m) }
            if let r = cfg.resolution { settings.resolution = r }
            if let c = cfg.color { settings.color = c }
        }
    }

    private func write() {
        guard let src = source else { return }
        let base = settings
        let pinBytes = usePIN ? hexBytes(pin) : nil
        let mfrField = manufacturer.trimmingCharacters(in: .whitespaces)
        let mfr = mfrField.isEmpty ? nil : hexBytes(mfrField)
        if usePIN && (pinBytes == nil || !(2...6).contains(pinBytes!.count)) { nfc.append("PIN must be 2–6 hex bytes"); return }
        if sendConfig && !mfrField.isEmpty && mfr?.count != 1 { nfc.append("Driver byte must be one hex byte, e.g. 70"); return }
        let doConfig = sendConfig, doMatch = matchTag && !sendConfig, hScan = horizontalScan

        nfc.wrapNDEF = wrapNDEF
        nfc.run { client, status in
            if let pinBytes { try await client.send(ESL.verifyPIN(pinBytes)) }

            // Ask the tag what panel it drives (Get Config Info, manual 7.4).
            var s = base
            var cfg: TagConfig?
            do {
                let c = try await client.readConfig()
                client.log("Tag config: \(c.summary)")
                cfg = c
            } catch {
                client.log("Could not read tag config (\(error.localizedDescription)) – using your settings")
            }

            if doMatch, let cfg, cfg.resolution != nil || cfg.color != nil {
                s.resolution = cfg.resolution ?? s.resolution
                s.color = cfg.color ?? s.color
                if s.resolution != base.resolution || s.color != base.color {
                    client.log("Matched image to tag: \(s.resolution.rawValue), \(s.color.rawValue)")
                }
                await apply(cfg)
            }

            if doConfig {
                guard let m = mfr?.first ?? cfg?.manufacturer else {
                    throw ESLError.message("Driver byte unknown – enter it or use Read tag info")
                }
                guard let sizeByte = s.resolution.sizeByte else {
                    throw ESLError.message("304 × 152 is a custom panel size; do not send DA screen config. The panel's DB driver flow must already be installed.")
                }
                try await client.send(ESL.setScreenType([m, sizeByte, s.color.colorByte]))
                try await client.send(ESL.setColorParams(s.color.colorParams, horizontalScan: hScan))
            }

            guard let p = ImageProcessor.render(src, s) else { throw ESLError.message("Image processing failed") }
            let planes = ImageProcessor.pack(p, rotation: s.rotation, mirror: s.mirror, color: s.color)
            try await client.writeImage(planes: planes) { pct in status("Sending… \(pct)%") }
            return "Done ✓"
        }
    }

    private func readInfo() {
        let pinBytes = usePIN ? hexBytes(pin) : nil
        nfc.wrapNDEF = wrapNDEF
        nfc.run { client, _ in
            if let pinBytes { try await client.send(ESL.verifyPIN(pinBytes)) }
            let cfg = try await client.readConfig()
            client.log("Config TLV  \(cfg.rawDescription)")
            await apply(cfg)
            return cfg.summary
        }
    }
}
