import SwiftUI

struct ChatInterfaceView: View {
    @EnvironmentObject var manager: HandyManager
    @EnvironmentObject var settings: AppSettings

    @State private var inputText = ""
    @State private var toolNameInput = ""
    @State private var showSettings = false
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(DS.Colors.border)

            if showSettings {
                SettingsView(isPresented: $showSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                chatContent
            }
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: DS.Spacing.sm) {
                statusDot
                Text("Handy")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            if manager.voiceState == .listening {
                listeningIndicator
            }

            Button(action: { withAnimation { showSettings.toggle() } }) {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(DS.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(statusColor.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .opacity(manager.voiceState == .listening ? 1 : 0)
                    .scaleEffect(manager.voiceState == .listening ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: manager.voiceState)
            )
    }

    private var statusColor: Color {
        switch manager.voiceState {
        case .idle: return DS.Colors.success
        case .listening: return DS.Colors.accent
        case .processing: return DS.Colors.warning
        case .responding: return DS.Colors.accent
        }
    }

    private var listeningIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Colors.accent)
                    .frame(width: 3, height: 12)
                    .scaleEffect(y: manager.voiceState == .listening ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: manager.voiceState
                    )
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            toolNameBar
            Divider().background(DS.Colors.borderSubtle)
            messageList
            if manager.isProcessing {
                loadingBar
            }
            if let error = manager.errorMessage {
                errorBar(error)
            }
            inputBar
        }
    }

    private var toolNameBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "app.badge")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            if manager.toolDetectionState == .detecting && manager.currentToolName.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Detecting app...")
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DS.Colors.textTertiary)
                }
            } else {
                TextField("Tool / App name", text: $toolNameInput)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .onSubmit {
                        if !toolNameInput.isEmpty {
                            manager.setToolName(toolNameInput)
                        }
                    }
                    .onChange(of: manager.currentToolName) { _, newValue in
                        if toolNameInput.isEmpty && !newValue.isEmpty {
                            toolNameInput = newValue
                        }
                    }
            }

            Spacer()

            if manager.toolDetectionState == .failed {
                yellowDotTrail
            }

            if !manager.currentToolName.isEmpty && manager.toolDetectionState != .detecting {
                Text(manager.currentToolName)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.accent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.surface)
        .animation(.easeInOut(duration: 0.2), value: manager.toolDetectionState)
    }

    private var yellowDotTrail: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DS.Colors.warning)
                    .frame(width: 4, height: 4)
                    .opacity(0.4 + Double(i) * 0.3)
            }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DS.Spacing.md) {
                    ForEach(manager.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
            }
            .onChange(of: manager.messages.count) { _, _ in
                if let lastID = manager.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var loadingBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(DS.Colors.accent)

            Text(manager.loadingVerb)
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .animation(.easeInOut, value: manager.loadingVerb)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.surface)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DS.Colors.error)
                .font(.system(size: 12))

            Text(message)
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.error)
                .lineLimit(2)

            Spacer()

            Button("Dismiss") {
                manager.errorMessage = nil
            }
            .font(DS.Typography.caption)
            .foregroundColor(DS.Colors.textTertiary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.errorSubtle)
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(DS.Colors.border)

            HStack(spacing: DS.Spacing.sm) {
                voiceButton

                ZStack(alignment: .leading) {
                    if manager.voiceState == .listening {
                        Text(manager.pendingTranscript.isEmpty ? "Listening..." : manager.pendingTranscript)
                            .font(DS.Typography.body)
                            .foregroundColor(manager.pendingTranscript.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                            .lineLimit(3)
                            .animation(.easeInOut(duration: 0.1), value: manager.pendingTranscript)
                    } else {
                        TextField("Ask anything...", text: $inputText)
                            .textFieldStyle(.plain)
                            .font(DS.Typography.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .onSubmit { sendCurrentInput() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                sendButton
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.surface)
    }

    private var voiceButton: some View {
        Button(action: {
            if manager.voiceState == .listening {
                manager.stopVoiceInput()
            } else {
                manager.startVoiceInput()
            }
        }) {
            Image(systemName: manager.voiceState == .listening ? "mic.fill" : "mic")
                .font(.system(size: 15))
                .foregroundColor(manager.voiceState == .listening ? DS.Colors.error : DS.Colors.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    manager.voiceState == .listening
                        ? DS.Colors.errorSubtle
                        : DS.Colors.surfaceElevated
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isProcessing)
    }

    private var sendButton: some View {
        Button(action: sendCurrentInput) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(inputText.isEmpty ? DS.Colors.textMuted : .white)
                .frame(width: 28, height: 28)
                .background(inputText.isEmpty ? DS.Colors.surfaceElevated : DS.Colors.accent)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(inputText.isEmpty || manager.isProcessing)
    }

    private func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if !toolNameInput.isEmpty {
            manager.setToolName(toolNameInput)
        }

        manager.sendMessage(text)
        inputText = ""
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            if message.role == .assistant {
                avatar
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: DS.Spacing.xs) {
                Text(message.content)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(3)

                if message.isStreaming {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(DS.Colors.accent)
                                .frame(width: 4, height: 4)
                                .opacity(0.6)
                                .scaleEffect(1.0)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.2),
                                    value: message.isStreaming
                                )
                        }
                    }
                }

                Text(timeString(message.timestamp))
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textMuted)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))

            if message.role == .user {
                userAvatar
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.accentSubtle)
                .frame(width: 28, height: 28)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.accent)
        }
    }

    private var userAvatar: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.surfaceElevated)
                .frame(width: 28, height: 28)
            Text("You")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return DS.Colors.userBubble
        case .assistant: return DS.Colors.assistantBubble
        case .system: return DS.Colors.errorSubtle
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
