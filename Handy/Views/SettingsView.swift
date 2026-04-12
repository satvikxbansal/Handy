import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var settings: AppSettings

    @State private var claudeKeyInput = ""
    @State private var openAIKeyInput = ""
    @State private var assemblyAIKeyInput = ""
    @State private var elevenLabsKeyInput = ""
    @State private var showClaudeKey = false
    @State private var showOpenAIKey = false
    @State private var showAssemblyAIKey = false
    @State private var showElevenLabsKey = false
    @State private var keySaveStatus: String?
    @State private var selectedSection: SettingsSection = .brain

    enum SettingsSection: String, CaseIterable {
        case brain = "Brain"
        case mode = "Mode"
        case trigger = "Trigger"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                sectionPicker
                
                switch selectedSection {
                case .brain:
                    brainSection
                case .mode:
                    modeSection
                case .trigger:
                    triggerSection
                }

                Spacer()
            }
            .padding(DS.Spacing.lg)
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .onAppear { loadExistingKeys() }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                Button(action: { selectedSection = section }) {
                    Text(section.rawValue)
                        .font(DS.Typography.bodySmall)
                        .foregroundColor(selectedSection == section ? .white : DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(selectedSection == section ? DS.Colors.accent : DS.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    // MARK: - Brain Section (API Keys)

    private var brainSection: some View {
        VStack(spacing: DS.Spacing.lg) {
            sectionHeader("LLM Provider", icon: "brain")

            apiKeyField(
                title: "Claude API Key",
                placeholder: "sk-ant-...",
                text: $claudeKeyInput,
                isRevealed: $showClaudeKey,
                keyType: .claude,
                isRequired: true
            )

            Divider().background(DS.Colors.borderSubtle)

            sectionHeader("Voice Providers", icon: "waveform")

            VStack(spacing: DS.Spacing.sm) {
                HStack {
                    Text("Speech-to-Text")
                        .font(DS.Typography.bodySmall)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("", selection: $settings.sttProvider) {
                        ForEach(STTProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                HStack {
                    Text("Text-to-Speech")
                        .font(DS.Typography.bodySmall)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("", selection: $settings.ttsProvider) {
                        ForEach(TTSProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
            }

            if settings.sttProvider == .openAI || settings.ttsProvider == .system {
                apiKeyField(
                    title: "OpenAI API Key",
                    placeholder: "sk-...",
                    text: $openAIKeyInput,
                    isRevealed: $showOpenAIKey,
                    keyType: .openAI,
                    isRequired: settings.sttProvider == .openAI
                )
            }

            if settings.sttProvider == .assemblyAI {
                apiKeyField(
                    title: "AssemblyAI API Key",
                    placeholder: "your-assembly-ai-key",
                    text: $assemblyAIKeyInput,
                    isRevealed: $showAssemblyAIKey,
                    keyType: .assemblyAI,
                    isRequired: true
                )
            }

            if settings.ttsProvider == .elevenLabs {
                apiKeyField(
                    title: "ElevenLabs API Key",
                    placeholder: "your-elevenlabs-key",
                    text: $elevenLabsKeyInput,
                    isRevealed: $showElevenLabsKey,
                    keyType: .elevenLabs,
                    isRequired: true
                )
            }

            if let status = keySaveStatus {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.success)
                        .font(.system(size: 12))
                    Text(status)
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.success)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Mode Section

    private var modeSection: some View {
        VStack(spacing: DS.Spacing.lg) {
            sectionHeader("Assistant Mode", icon: "sparkles")

            VStack(spacing: DS.Spacing.sm) {
                modeCard(
                    mode: .helpOnly,
                    icon: "questionmark.circle",
                    title: "Help Only",
                    description: "Answers your questions and helps navigate. Only responds when you ask."
                )

                modeCard(
                    mode: .tutor,
                    icon: "graduationcap",
                    title: "Tutor",
                    description: "Proactively guides you through the app you're using. Uses Claude API tokens when idle."
                )
            }

            if settings.assistantMode == .tutor {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .foregroundColor(DS.Colors.warning)
                        .font(.system(size: 12))
                    Text("Tutor mode will periodically observe your screen and use API tokens even when you haven't asked a question.")
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.warning)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
        }
    }

    // MARK: - Trigger Section

    private var triggerSection: some View {
        VStack(spacing: DS.Spacing.lg) {
            sectionHeader("Keyboard Shortcuts", icon: "keyboard")

            VStack(spacing: DS.Spacing.md) {
                triggerRow(
                    label: "Open Chat",
                    shortcut: "⇧ Space O",
                    description: "Opens the chat interface"
                )
                triggerRow(
                    label: "Voice Input",
                    shortcut: "⇧ Space",
                    description: "Start/stop voice input"
                )
            }

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "info.circle")
                    .foregroundColor(DS.Colors.textTertiary)
                    .font(.system(size: 12))
                Text("Custom hotkeys coming in v2")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(DS.Spacing.md)
            .background(DS.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.accent)
            Text(title)
                .font(DS.Typography.titleSmall)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
        }
    }

    private func apiKeyField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isRevealed: Binding<Bool>,
        keyType: KeychainManager.APIKeyType,
        isRequired: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(title)
                    .font(DS.Typography.bodySmall)
                    .foregroundColor(DS.Colors.textSecondary)
                if isRequired {
                    Text("Required")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Colors.accentSubtle)
                        .clipShape(Capsule())
                }
                Spacer()
                if KeychainManager.hasAPIKey(keyType) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.success)
                        .font(.system(size: 12))
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                Group {
                    if isRevealed.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textFieldStyle(.plain)
                .font(DS.Typography.mono)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .stroke(DS.Colors.border, lineWidth: 1)
                )

                Button(action: { isRevealed.wrappedValue.toggle() }) {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button(action: { saveKey(text.wrappedValue, type: keyType) }) {
                    Text("Save")
                        .font(DS.Typography.bodySmall)
                        .foregroundColor(.white)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(text.wrappedValue.isEmpty ? DS.Colors.surfaceElevated : DS.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .disabled(text.wrappedValue.isEmpty)
            }

            if KeychainManager.hasAPIKey(keyType) {
                Text("Stored: \(KeychainManager.maskedKey(keyType))")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textMuted)
            }
        }
    }

    private func modeCard(mode: AssistantMode, icon: String, title: String, description: String) -> some View {
        Button(action: { settings.assistantMode = mode }) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(settings.assistantMode == mode ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(settings.assistantMode == mode ? DS.Colors.accentSubtle : DS.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Typography.titleSmall)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(description)
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                if settings.assistantMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Colors.accent)
                }
            }
            .padding(DS.Spacing.md)
            .background(settings.assistantMode == mode ? DS.Colors.accentSubtle.opacity(0.3) : DS.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .stroke(settings.assistantMode == mode ? DS.Colors.accent.opacity(0.5) : DS.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func triggerRow(label: String, shortcut: String, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.Typography.bodySmall)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(description)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Text(shortcut)
                .font(DS.Typography.mono)
                .foregroundColor(DS.Colors.accent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(DS.Colors.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }

    // MARK: - Key Management

    private func loadExistingKeys() {
        claudeKeyInput = KeychainManager.getAPIKey(.claude) ?? ""
        openAIKeyInput = KeychainManager.getAPIKey(.openAI) ?? ""
        assemblyAIKeyInput = KeychainManager.getAPIKey(.assemblyAI) ?? ""
        elevenLabsKeyInput = KeychainManager.getAPIKey(.elevenLabs) ?? ""
    }

    private func saveKey(_ value: String, type: KeychainManager.APIKeyType) {
        do {
            try KeychainManager.saveAPIKey(type, value: value)
            withAnimation {
                keySaveStatus = "Key saved securely"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { keySaveStatus = nil }
            }
        } catch {
            keySaveStatus = nil
        }
    }
}
