import SwiftUI

struct ContentView: View {
    @StateObject private var store = ChatStore()
    @State private var showSettings = false
    @State private var showSidebar = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                modelBar
                Divider()
                messageList
                composer
            }
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .environmentObject(store)
    }

    private var sidebar: some View {
        VStack {
            HStack {
                Text("PositionAI").font(.headline)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }.buttonStyle(.borderless)
            }
            .padding()

            Button(action: store.newChat) {
                Label("New chat", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            List {
                ForEach(store.conversations) { convo in
                    HStack {
                        Image(systemName: "bubble.left")
                        Text(convo.title.isEmpty ? "New chat" : convo.title)
                            .lineLimit(1)
                        Spacer()
                        if convo.id == store.currentID {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.currentID = convo.id }
                    .contextMenu {
                        Button(role: .destructive) { store.deleteChat(convo.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }

    private var modelBar: some View {
        HStack {
            Image(systemName: "cpu")
            Picker("", selection: $store.selectedModel) {
                ForEach(store.models) { m in
                    Label(m.name, systemImage: m.icon).tag(m.id)
                }
            }
            .frame(maxWidth: 360)
            if store.models.isEmpty {
                Button("Load models") { Task { try? await store.loadModels() } }
            }
            Spacer()
            if store.sending {
                Button("Stop") { store.stop() }
            }
            if let err = store.errorMessage {
                Text(err).font(.caption).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.current?.messages ?? []) { message in
                        HStack(alignment: .top) {
                            Image(systemName: message.role == "user" ? "person.circle" : "brain")
                                .font(.title2)
                                .foregroundColor(message.role == "user" ? .blue : .purple)
                            VStack(alignment: .leading) {
                                Text(message.role == "user" ? "You" : "Assistant")
                                    .font(.caption).bold()
                                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                                    .textSelection(.enabled)
                                if message.isStreaming { ProgressView().scaleEffect(0.6) }
                            }
                            Spacer()
                        }
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: store.current?.messages.last?.content) { _ in
                if let last = store.current?.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom) {
                TextEditor(text: $store.input)
                    .frame(minHeight: 44, maxHeight: 140)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                Button(action: store.send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(store.sending || store.input.isEmpty || store.selectedModel.isEmpty)
                .buttonStyle(.borderless)
            }
            Text("⌘ + Enter to send · API key in Settings")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .onReceive(NotificationCenter.default.publisher(for: .sendMessage)) { _ in store.send() }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2).bold()
            SecureField("PositionAPI key (sk-…)", text: $keyDraft)
            Text("Stored locally in UserDefaults. Get a key at positionapi.top.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text("Max tokens"); Slider(value: Binding(
                    get: { Double(store.maxTokens) },
                    set: { store.maxTokens = Int($0) }
                ), in: 256...16384, step: 256)
                Text("\(store.maxTokens)").monospacedDigit()
            }
            HStack {
                Text("Temperature"); Slider(value: $store.temperature, in: 0...2, step: 0.1)
                Text(String(format: "%.1f", store.temperature)).monospacedDigit()
            }
            TextField("System prompt (optional)", text: $store.systemPrompt)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save & load models") {
                    store.key = keyDraft.trimmingCharacters(in: .whitespaces)
                    Task {
                        try? await store.loadModels()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 320)
        .onAppear { keyDraft = store.key }
    }
}

extension Notification.Name {
    static let sendMessage = Notification.Name("sendMessage")
}
