import AppKit
import SwiftUI

/// "Get Info" panel, including the one attribute a transfer client really needs
/// to be able to change: the POSIX mode.
///
/// Laid out as the Finder's info window is — a header with the big icon, then
/// sections — on cards instead of disclosure triangles. Permissions can be set
/// three ways that stay in sync: the R/W/X pills, the octal field, or a preset.
struct InfoInspector: View {
    let entry: RemoteEntry
    let onApplyPermissions: (UInt16) -> Void
    let onClose: () -> Void

    @State private var owner: Permission
    @State private var group: Permission
    @State private var others: Permission
    @State private var octalText: String
    @State private var copied = false

    struct Permission: Equatable {
        var read = false
        var write = false
        var execute = false

        init(bits: UInt16) {
            read = bits & 0b100 != 0
            write = bits & 0b010 != 0
            execute = bits & 0b001 != 0
        }

        var bits: UInt16 {
            (read ? 0b100 : 0) | (write ? 0b010 : 0) | (execute ? 0b001 : 0)
        }
    }

    /// Modes people actually set, with what they are for.
    private static let presets: [(mode: UInt16, label: String)] = [
        (0o644, "Files"),
        (0o755, "Folders, scripts"),
        (0o600, "Private file"),
        (0o700, "Private folder"),
        (0o775, "Shared folder"),
    ]

    init(entry: RemoteEntry, onApplyPermissions: @escaping (UInt16) -> Void, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onApplyPermissions = onApplyPermissions
        self.onClose = onClose
        let mode = (entry.permissions ?? 0) & 0o777
        _owner = State(initialValue: Permission(bits: (mode >> 6) & 0b111))
        _group = State(initialValue: Permission(bits: (mode >> 3) & 0b111))
        _others = State(initialValue: Permission(bits: mode & 0b111))
        _octalText = State(initialValue: String(format: "%03o", mode))
    }

    private var mode: UInt16 {
        (owner.bits << 6) | (group.bits << 3) | others.bits
    }

    private var originalMode: UInt16 { (entry.permissions ?? 0) & 0o777 }
    private var hasChanges: Bool { mode != originalMode }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)

            VStack(spacing: 14) {
                generalCard
                permissionsCard
            }
            .padding(.horizontal, 18)

            footer
                .padding(18)
        }
        .frame(width: 460)
        .onChange(of: mode) { _, newMode in
            let text = String(format: "%03o", newMode)
            if octalText != text { octalText = text }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: FileIcon.image(for: entry, size: 72))
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Modified \(entry.displayModified)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerSubtitle: String {
        entry.isDirectory ? entry.kindLabel : "\(entry.kindLabel) — \(entry.displaySize)"
    }

    // MARK: - General

    private var generalCard: some View {
        card("General", systemImage: "info.circle.fill") {
            VStack(spacing: 0) {
                row("Kind") { Text(entry.kindLabel) }
                rowDivider
                if !entry.isDirectory {
                    row("Size") {
                        Text("\(entry.displaySize) (\(entry.size.formatted(.number)) bytes)")
                    }
                    rowDivider
                }
                row("Modified") { Text(entry.displayModified) }
                rowDivider
                row("Where") {
                    HStack(spacing: 6) {
                        Text(entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(entry.path)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.path, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help("Copy path")
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        card("Permissions", systemImage: "lock.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // The mode as text, editable in octal.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(symbolic(mode))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(hasChanges ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                    Spacer()
                    Text("Octal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("", text: $octalText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 58)
                        .onSubmit(applyOctal)
                        .onChange(of: octalText) { _, _ in applyOctal() }
                }

                VStack(spacing: 8) {
                    permissionRow("Owner", systemImage: "person.fill", $owner)
                    permissionRow("Group", systemImage: "person.2.fill", $group)
                    permissionRow("Everyone", systemImage: "globe.europe.africa.fill", $others)
                }

                // Presets.
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.mode) { preset in
                            Button {
                                set(preset.mode)
                            } label: {
                                Text(String(format: "%03o", preset.mode))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        mode == preset.mode ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.primary.opacity(0.07)),
                                        in: .capsule
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(preset.label)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func permissionRow(_ title: String, systemImage: String, _ permission: Binding<Permission>) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .frame(width: 110, alignment: .leading)
            Spacer(minLength: 0)
            pill("Read", isOn: permission.read)
            pill("Write", isOn: permission.write)
            pill("Execute", isOn: permission.execute)
        }
    }

    /// A toggle drawn as a capsule: tinted when on.
    private func pill(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 62, height: 24)
                .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(
                    isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.07)),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func applyOctal() {
        let digits = octalText.filter(\.isNumber)
        guard digits.count == 3, digits.allSatisfy({ $0 < "8" }), let value = UInt16(digits, radix: 8) else { return }
        if value != mode { set(value) }
    }

    private func set(_ newMode: UInt16) {
        withAnimation(.snappy(duration: 0.15)) {
            owner = Permission(bits: (newMode >> 6) & 0b111)
            group = Permission(bits: (newMode >> 3) & 0b111)
            others = Permission(bits: newMode & 0b111)
        }
    }

    private func symbolic(_ mode: UInt16) -> String {
        let prefix = entry.isDirectory ? "d" : "-"
        let flags = ["r", "w", "x"]
        var result = prefix
        for shift in stride(from: 6, through: 0, by: -3) {
            let triad = (mode >> UInt16(shift)) & 0b111
            for (index, flag) in flags.enumerated() {
                result += (triad & (0b100 >> UInt16(index))) != 0 ? flag : "-"
            }
        }
        return result
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if hasChanges {
                Button("Revert") { set(originalMode) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            Button {
                onApplyPermissions(mode)
            } label: {
                Text("Apply").fontWeight(.semibold).padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .disabled(!hasChanges)
        }
        .controlSize(.large)
        .animation(.snappy(duration: 0.15), value: hasChanges)
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
    }

    private var rowDivider: some View {
        Divider().opacity(0.5)
    }
}
