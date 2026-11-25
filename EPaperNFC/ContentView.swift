import SwiftUI
import PhotosUI

// MARK: - Theme

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.10, green: 0.07, blue: 0.20), Color(red: 0.03, green: 0.03, blue: 0.07)],
        startPoint: .top, endPoint: .bottom)
    static let accent = LinearGradient(
        colors: [Color(red: 1.00, green: 0.84, blue: 0.15), Color(red: 0.98, green: 0.30, blue: 0.22)],
        startPoint: .leading, endPoint: .trailing)
    static let yellow = Color(red: 0.94, green: 0.78, blue: 0.0)
    static let red = Color(red: 0.85, green: 0.12, blue: 0.12)
    static let card = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.12)
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Main screen

struct ContentView: View {
    @StateObject private var nfc = NFCManager()
    @State private var pickerItem: PhotosPickerItem?
    @State private var source: UIImage?
    @State private var settings = ImageSettings()
    @State private var processed: Processed?
    @State private var showAdjust = false
    @State private var showAdvanced = false

    // Advanced
    @State private var forceNDEF = false
    @State private var usePIN = false
    @State private var pin = "1122334455"
    @State private var detectScreen = false
    @State private var tagInfo: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 22) {
                header
                Spacer(minLength: 0)
                previewCard
                statusPill
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAdjust) {
            AdjustSheet(settings: $settings, preview: processed?.preview)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAdvanced) { advancedSheet }
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("E-Paper")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text("1.54″ · 152 × 152 · 4 colours")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            HStack(spacing: -6) {
                ForEach([Color.black, .white, Theme.yellow, Theme.red], id: \.self) { c in
                    Circle().fill(c)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                }
            }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                // Glow
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Theme.accent)
                    .blur(radius: 40)
                    .opacity(processed == nil ? 0.15 : 0.35)

                // Device bezel
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(white: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1.5))

                // Screen
                Group {
                    if let p = processed {
                        Image(uiImage: p.preview)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 44, weight: .light))
                            Text("Tap to choose a photo")
                                .font(.headline)
                        }
                        .foregroundStyle(.black.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.9))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(22)

                if processed != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label("Change", systemImage: "photo")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(30)
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder private var statusPill: some View {
        if nfc.busy || nfc.log.last != nil {
            let line = nfc.busy ? "Hold your iPhone on the tag…" : (nfc.log.last ?? "")
            let isError = line.hasPrefix("Error") || line.hasPrefix("Session ended")
            let isDone = line.contains("Done")
            HStack(spacing: 8) {
                Image(systemName: nfc.busy ? "wave.3.right" :
                        isError ? "exclamationmark.triangle.fill" :
                        isDone ? "checkmark.circle.fill" : "info.circle")
                Text(line).lineLimit(2)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(isError ? Color(red: 1, green: 0.5, blue: 0.45) : isDone ? .green : .white.opacity(0.8))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke))
            .transition(.opacity)
        }
    }

    // MARK: Buttons

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                secondaryButton("Adjust", icon: "slider.horizontal.3") { showAdjust = true }
                    .disabled(source == nil)
                    .opacity(source == nil ? 0.4 : 1)
                secondaryButton("Advanced", icon: "gearshape.fill") { showAdvanced = true }
            }

            Button(action: write) {
                HStack(spacing: 10) {
                    if nfc.busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "wave.3.right")
                    }
                    Text(nfc.busy ? "Updating…" : "Update Tag")
                }
                .font(.title3.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Theme.red.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(PressableStyle())
            .disabled(source == nil || nfc.busy)
            .opacity(source == nil ? 0.4 : 1)
        }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Advanced

    private var advancedSheet: some View {
        NavigationStack {
            Form {
                Section("Panel orientation") {
                    Picker("Rotation", selection: $settings.rotation) {
                        Text("0°").tag(0); Text("90°").tag(1); Text("180°").tag(2); Text("270°").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Mirror", isOn: $settings.mirror)
                }

                Section {
                    Button { readInfo() } label: { Label("Read tag info", systemImage: "info.circle") }
                        .disabled(nfc.busy)
                    if let tagInfo { Text(tagInfo).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Tag")
                }

                Section {
                    Toggle("Always use iOS NDEF mode (slower)", isOn: $forceNDEF)
                    Toggle("Verify PIN first", isOn: $usePIN)
                    if usePIN {
                        TextField("PIN (hex)", text: $pin)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Toggle("Check panel before refresh", isOn: $detectScreen)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The app uses fast direct mode when the tag allows it and switches to NDEF mode by itself. Enable PIN if you get error 6982 (default 1122334455). "
                         + "Leave “Check panel” off if you get error 68C6.")
                }

                Section("Log") {
                    if nfc.log.isEmpty {
                        Text("No activity yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(nfc.log.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                    if !nfc.log.isEmpty { Button("Clear log", role: .destructive) { nfc.log.removeAll() } }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showAdvanced = false } }
            }
        }
    }

    // MARK: Actions

    private func update() {
        guard let source else { return }
        processed = ImageProcessor.render(source, settings)
    }

    /// PIN bytes to verify: [] = no PIN, nil = invalid (error logged).
    private func pinToSend() -> [UInt8]? {
        guard usePIN else { return [] }
        guard let b = hexBytes(pin), (2...6).contains(b.count) else {
            nfc.append("Error: PIN must be 2–6 hex bytes"); return nil
        }
        return b
    }

    private func write() {
        guard let src = source, let pinBytes = pinToSend() else { return }
        let s = settings
        let detect = detectScreen
        nfc.forceNDEF = forceNDEF
        nfc.run { client, status in
            if !pinBytes.isEmpty { try await client.send(ESL.verifyPIN(pinBytes)) }

            var codes = Panel.defaultCodes
            if let cfg = try? await client.readConfig() {
                client.log("Tag config: \(cfg.summary)")
                if !cfg.matchesPanel { client.log("Warning: tag is not set up as a 152×152 4-colour panel") }
                if let c = cfg.colorCodes { codes = c }
            }
            client.log("Colour codes: \(Panel.describe(codes))")

            guard let p = ImageProcessor.render(src, s) else { throw ESLError.message("Image processing failed") }
            let plane = ImageProcessor.pack(p, rotation: s.rotation, mirror: s.mirror, codes: codes)
            try await client.writeImage(planes: [plane], detectScreen: detect, status: status)
            return "Done ✓"
        }
    }

    private func readInfo() {
        guard let pinBytes = pinToSend() else { return }
        nfc.forceNDEF = forceNDEF
        nfc.run { client, _ in
            if !pinBytes.isEmpty { try await client.send(ESL.verifyPIN(pinBytes)) }
            let cfg = try await client.readConfig()
            client.log("Config TLV  \(cfg.rawDescription)")
            let codes = cfg.colorCodes.map { "Colour codes from tag: \(Panel.describe($0))" }
                ?? "No colour codes on tag – using \(Panel.describe(Panel.defaultCodes))"
            let info = cfg.summary + (cfg.matchesPanel ? "\n✓ Matches this app (152×152, 4 colours)"
                                                       : "\n⚠︎ Not a 152×152 4-colour config")
                + "\n" + codes
            await MainActor.run { tagInfo = info }
            return cfg.summary
        }
    }
}

// MARK: - Adjust sheet

struct AdjustSheet: View {
    @Binding var settings: ImageSettings
    let preview: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: Theme.yellow.opacity(0.3), radius: 12)
                    }

                    VStack(spacing: 16) {
                        slider("Brightness", icon: "sun.max.fill", value: $settings.brightness, range: -0.5...0.5)
                        slider("Contrast", icon: "circle.lefthalf.filled", value: $settings.contrast, range: 0.5...2.0)
                        slider("Zoom", icon: "plus.magnifyingglass", value: $settings.zoom, range: 1...3)
                        Toggle(isOn: $settings.dither) {
                            Label("Dithering", systemImage: "circle.grid.3x3.fill")
                        }
                        .tint(Theme.red)
                    }
                    .padding(18)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))

                    Button {
                        settings.brightness = 0; settings.contrast = 1; settings.zoom = 1; settings.dither = true
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(Theme.yellow)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func slider(_ title: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: value, in: range).tint(Theme.yellow)
        }
    }
}
