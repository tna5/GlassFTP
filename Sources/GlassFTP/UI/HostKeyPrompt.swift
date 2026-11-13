import SwiftUI

/// First-contact host key confirmation, mirroring what `ssh` asks in Terminal.
struct HostKeyPrompt: View {
    let challenge: HostKeyChallenge
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Verify the identity of \(challenge.host)")
                        .font(.headline)
                    Text("GlassFTP has never connected to this server before, so there is no saved key to compare against.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Server") {
                    Text(challenge.port == 22 ? challenge.host : "\(challenge.host):\(challenge.port)")
                        .textSelection(.enabled)
                }
                LabeledContent("Key type") {
                    Text(challenge.algorithm)
                        .textSelection(.enabled)
                }
                LabeledContent("Fingerprint") {
                    Text(challenge.fingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Theme.controlRadius))

            Text("Compare this fingerprint with one you obtained from the server operator through a channel you trust. Accepting saves it to ~/.ssh/known_hosts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { onDecision(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trust and Connect") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
