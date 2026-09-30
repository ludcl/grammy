import SwiftUI
import AppKit

struct RewriteView: View {
    @ObservedObject var model: RewriteModel
    var settings: () -> Void
    private let accent = Color(red: 0.05, green: 0.48, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 25)).foregroundStyle(accent)
                    .frame(width: 48, height: 48).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your words, a little clearer.").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(model.sourceName + " · Keep the tone. Keep the emojis.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape").font(.title3) }
                    .buttonStyle(.plain).help("Settings")
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    label("ORIGINAL", icon: "text.alignleft")
                    if model.hasTarget || model.isSample {
                        ScrollView {
                            Text(model.original).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        TextEditor(text: $model.original)
                            .scrollContentBackground(.hidden).padding(8)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            .disabled(model.isBusy)
                            .onChange(of: model.original) { _, _ in
                                model.isComplete = false; model.suggestion = ""; model.error = nil
                            }
                            .overlay(alignment: .topLeading) {
                                if model.original.isEmpty {
                                    Text("Paste a message here, or select text in Slack and use Services → Improve Slack message.")
                                        .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                                }
                            }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        label("SUGGESTION", icon: "sparkles")
                        Spacer()
                        if model.isSample { Text("SAMPLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                        if model.isBusy { ProgressView().controlSize(.small) }
                    }
                    TextEditor(text: $model.suggestion)
                        .scrollContentBackground(.hidden).padding(8)
                        .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.2), lineWidth: 1))
                        .disabled(model.isBusy || !model.isComplete || model.isReplacing)
                        .overlay(alignment: .topLeading) {
                            if model.suggestion.isEmpty {
                                Text(model.isBusy ? "Polishing your message…" : "Your improved message will appear here. You can edit it before replacing.")
                                    .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                            }
                        }
                }
            }.font(.system(size: 15)).lineSpacing(4)

            if let error = model.error ?? model.emojiWarning {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.usedFallback {
                Label("ChatGPT unavailable · Using Gemini 3.5 Flash-Lite", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(model.isSample ? "Sample preview · No request sent" :
                        (model.providerName.isEmpty ? "Only the text you choose is sent." : "Rewriting with \(model.providerName)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isReplacing)
                Button(model.isComplete ? "Regenerate" : "Improve message") { model.generate() }
                    .disabled(model.isBusy || model.isReplacing || model.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(model.hasTarget ? "Replace" : "Copy suggestion") { model.accept() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(!model.canAccept)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(26)
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func label(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
    }
}

struct SettingsView: View {
    @ObservedObject var account: ChatGPTAccount
    @ObservedObject var gemini: GeminiAccount
    @State private var geminiKey = ""
    var sample: () -> Void
    var stopRewriting: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.email ?? "Connect your ChatGPT account").font(.headline)
                        Text("Use your plan allowance for on-demand rewrites.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.isBusy { ProgressView().controlSize(.small) }
                }
                if account.isSignedIn {
                    Picker("Model", selection: $account.selectedModel) {
                        if account.models.isEmpty { Text("Load available models").tag("") }
                        ForEach(account.models) { model in Text(model.display_name).tag(model.slug) }
                    }
                    HStack {
                        Button("Refresh models") { Task { await account.loadModels() } }
                        Button("Reconnect") { stopRewriting(); account.signIn() }
                        Button("Sign out") { stopRewriting(); Task { await account.signOut() } }
                    }.disabled(account.isBusy)
                } else {
                    Button("Continue with ChatGPT") { account.signIn() }
                        .buttonStyle(.borderedProminent).disabled(account.isBusy)
                }
                HStack {
                    Button("Use another account") { stopRewriting(); account.signIn(differentAccount: true) }.disabled(account.isBusy)
                    if account.isBusy { Button("Cancel sign-in") { account.cancelSignIn() } }
                }
                if let message = account.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Link("Manage usage and app access in ChatGPT", destination: URL(string: "https://chatgpt.com/#settings")!)
                Text("Enterprise access depends on your workspace’s permissions. Each person sharing this app signs in with their own account.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("ChatGPT") }

            Section {
                LabeledContent("Model", value: "gemini-3.5-flash-lite")
                SecureField(gemini.hasKey ? "Replace saved API key" : "Google AI Studio API key", text: $geminiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save key & enable fallback") {
                        stopRewriting()
                        if gemini.save(geminiKey) { geminiKey = "" }
                    }.disabled(geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if gemini.hasKey {
                        Button("Test connection") { gemini.testConnection() }.disabled(gemini.isTesting)
                        Button("Remove key") { stopRewriting(); gemini.remove(); geminiKey = "" }
                    }
                    if gemini.isTesting { ProgressView().controlSize(.small) }
                }
                Toggle("Use Gemini when ChatGPT is unavailable", isOn: $gemini.isEnabled)
                    .disabled(!gemini.hasKey)
                    .onChange(of: gemini.isEnabled) { _, _ in stopRewriting() }
                if let message = gemini.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else if gemini.hasKey {
                    Label("API key saved in Keychain", systemImage: "checkmark.shield").font(.caption)
                }
                Text("When enabled, Gemini receives the selected text if ChatGPT is unavailable. Google AI Studio quota and billing apply separately. Test connection sends a short sample message.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Google AI Studio fallback") }

            Section {
                Text("Select text in Slack, right-click, and look under Services for Improve Slack message. Menu placement depends on Slack.")
                LabeledContent("Global shortcut", value: "⌃⌥⌘G")
                HStack {
                    Button("Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("Keyboard settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
                Text("The shortcut needs Accessibility permission. Services can work without it. In Keyboard → Keyboard Shortcuts → Services, enable Grammy’s action if it is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Use in Slack and other apps") }

            Section {
                Text("Grammy sends your selected text to ChatGPT, or to Gemini when fallback is enabled and needed, only when you request a rewrite or regenerate. Drafts and suggestions stay in memory; credentials are stored in Keychain.")
                    .font(.callout)
                Text("This prototype inserts plain text. Review Slack mentions, links, formatting and custom emojis after replacing. It never presses Send.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show sample preview") { sample() }
            } header: { Text("Personal prototype") }
        }
        .formStyle(.grouped).frame(width: 580, height: 640)
        .task { if account.isSignedIn { await account.loadModels() } }
    }
}
