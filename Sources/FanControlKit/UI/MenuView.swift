import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: FanController
    @State private var newProfileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            temperatureSection
            Divider()
            fanSection
            Divider()
            profileSection
            if let warning = controller.warningMessage {
                Divider()
                warningBanner(warning)
            }
            Divider()
            footerButtons
        }
        .padding(14)
        .frame(width: 290)
    }

    // MARK: - Sections

    private var temperatureSection: some View {
        row("Temp",
            value: controller.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Fan Speed", icon: "fan")
            fanSlider(
                label: "Left",
                actual: controller.fan0RPM,
                target: $controller.fan0Target,
                min: controller.fan0Min,
                max: controller.fan0Max
            ) { controller.setFan0Speed($0) }

            fanSlider(
                label: "Right",
                actual: controller.fan1RPM,
                target: $controller.fan1Target,
                min: controller.fan1Min,
                max: controller.fan1Max
            ) { controller.setFan1Speed($0) }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Profiles", icon: "list.bullet")

            if !controller.profiles.isEmpty {
                ForEach(controller.profiles) { profile in
                    HStack {
                        Button(profile.name) { controller.loadProfile(profile) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                        Spacer()
                        Button {
                            controller.deleteProfile(profile)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Save") {
                    controller.saveProfile(name: newProfileName)
                    newProfileName = ""
                }
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                .font(.system(size: 12))
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Auto") { controller.resetToAutomatic() }
                    .help("Let Apple SMC manage fan speeds automatically")
                Spacer()
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
            HStack {
                if DebugFlags.showSMCDump {
                    Button("SMC Dump") { controller.copySmcDump() }
                        .help("Copy SMC keys/types/values to clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: "thermometer.medium")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(value).monospacedDigit().font(.system(size: 12))
        }
    }

    private func fanSlider(
        label: String,
        actual: Double?,
        target: Binding<Double>,
        min: Double,
        max: Double,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Group {
                    if let rpm = actual {
                        Text("actual \(Int(rpm)) RPM")
                    } else {
                        Text("— RPM")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
            }

            HStack(spacing: 4) {
                Text("\(Int(min))").font(.system(size: 9)).foregroundColor(.secondary)
                Slider(
                    value: target,
                    in: min...Swift.max(max, min + 1),
                    step: 100
                ) { editing in
                    if !editing { onCommit(target.wrappedValue) }
                }
                Text("\(Int(max))").font(.system(size: 9)).foregroundColor(.secondary)
            }

            RPMEntryField(min: min, max: max, onCommit: { rpm in
                target.wrappedValue = rpm
                onCommit(rpm)
            })
        }
    }

    private func warningBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Manual RPM Entry

private struct RPMEntryField: View {
    let min: Double
    let max: Double
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Set RPM…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .focused($focused)
                .onSubmit { commit() }
            Button("Set") { commit() }
                .font(.system(size: 11))
                .disabled(!isValid)
        }
    }

    private var isValid: Bool {
        Double(text.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func commit() {
        guard let rpm = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = Swift.min(Swift.max(rpm, min), max)
        onCommit(clamped)
        text = ""
        focused = false
    }
}
