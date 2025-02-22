import SwiftUI
import Combine
import AppKit
import Highlighter

// Define the OllamaResponse struct
struct OllamaResponse: Codable {
    let response: String
    let done: Bool
    let model: String
    let created_at: String
}

// ModelsResponse and Model structs
struct ModelsResponse: Codable {
    let models: [Model]
}

struct Model: Codable {
    let name: String
    let model: String
    let modified_at: String
    let size: Int64
    let digest: String
    let details: Details

    struct Details: Codable {
        let parent_model: String
        let format: String
        let family: String
        let families: [String]
        let parameter_size: String
        let quantization_level: String
    }
}

// Chat and Message structs
struct Chat: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var messages: [Message]
    var nameSuggestion: String? = nil

    static func ==(lhs: Chat, rhs: Chat) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Message: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let isUser: Bool

    static func == (lhs: Message, rhs: Message) -> Bool {
        return lhs.id == rhs.id
    }
}

@MainActor // Mark ChatStore as MainActor for Swift 6 concurrency safety
class ChatStore: ObservableObject {
    @Published var chats: [Chat] = [Chat(title: "New Chat", messages: [])]
    @Published var selectedChatId: Chat.ID?
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = ""
    @Published var messageInput: String = ""
    @Published var isLoading: Bool = false

    private var cancellables = Set<AnyCancellable>()

    func generateIntelligentNameSuggestion(for chat: Chat, selectedModel: String) async throws -> String? {
        guard !chat.messages.isEmpty else { return nil }

        let combinedMessages = chat.messages.map { $0.content }.joined(separator: "\n")
        let prompt = "Summarize the main topic of the following conversation in 5 words or less:\n\(combinedMessages)"

        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
            print("Invalid URL for Ollama API generate endpoint")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "stream": false
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("Invalid response from Ollama API (generate)")
            return nil
        }

        let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return ollamaResponse.response
    }

    func updateChat(chat: Chat) {
        if let index = self.chats.firstIndex(where: { $0.id == chat.id }) {
            self.chats[index] = chat
            // Notify any observers of the change
            objectWillChange.send()
        }
    }
}

struct ContentView: View {
    @StateObject private var chatStore = ChatStore()

    var body: some View {
        NavigationView {
            List(chatStore.chats, selection: $chatStore.selectedChatId) { chat in
                NavigationLink(destination: ChatDetailView(chatStore: chatStore, chat: Binding(
                    get: { chatStore.chats.first(where: { $0.id == chat.id })! },
                    set: { newValue in
                        if let index = chatStore.chats.firstIndex(where: { $0.id == chat.id }) {
                            chatStore.chats[index] = newValue
                            chatStore.updateChat(chat: newValue) // Ensure the store updates and notifies
                        }
                    }
                ))) {
                    Text(chat.title)
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                Button(action: { createNewChat() }) {
                    Image(systemName: "plus")
                }
            }

            Text("Select a chat or create a new one")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.1))
        }
        .onAppear(perform: fetchModels)
    }

    private func createNewChat() {
        let newChat = Chat(title: "New Chat", messages: [])
        chatStore.chats.append(newChat)
        chatStore.selectedChatId = newChat.id
    }

    private func fetchModels() {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
            print("Invalid URL for Ollama API")
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("Error fetching models: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("Invalid response from Ollama API")
                return
            }
            if let data = data {
                do {
                    let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
                    DispatchQueue.main.async {
                        self.chatStore.availableModels = modelsResponse.models.map { $0.name }
                        if !self.chatStore.availableModels.isEmpty {
                            self.chatStore.selectedModel = self.chatStore.availableModels[0]
                        }
                    }
                } catch {
                    print("Decoding error: \(error.localizedDescription)")
                }
            }
        }.resume()
    }
}

struct ChatMessageView: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                Text(message.content)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
            } else {
                // Check if the message contains a code block (```)
                if message.content.contains("```") {
                    let (code, language) = extractLanguage(from: message.content)
                    CodeView(text: message.content, code: code, language: language)
                        .padding()
                        .background(Color(NSColor.systemGray.withAlphaComponent(0.5)))
                        .cornerRadius(16)
                    Spacer()
                } else {
                    Text(message.content)
                        .padding()
                        .background(Color(NSColor.systemGray.withAlphaComponent(0.5)))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                    Spacer()
                }
            }
        }
    }
    
    private func extractLanguage(from text: String) -> (code: String, language: String) {
        let lines = text.split(separator: "\n")
        var code = text
        var language = "plaintext"
        
        if text.hasPrefix("```") {
            if lines.count > 0 {
                let firstLine = String(lines[0])
                let langIdentifier = firstLine.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespaces)
                if !langIdentifier.isEmpty {
                    language = langIdentifier
                    // Remove the opening and closing ``` lines
                    code = lines.dropFirst().dropLast().joined(separator: "\n")
                } else {
                    // If no language is specified, default to plaintext but still treat as code
                    language = "plaintext"
                    code = lines.dropFirst().dropLast().joined(separator: "\n")
                }
            }
        }
        
        return (code, language.lowercased())
    }
    
    private func normalizeLanguage(_ language: String) -> String {
        switch language {
        case "py", "python": return "python"
        case "js", "javascript": return "javascript"
        case "swift": return "swift"
        case "java": return "java"
        case "cpp", "c++": return "cpp"
        case "cs", "csharp": return "csharp"
        case "rb", "ruby": return "ruby"
        case "go": return "go"
        case "rs", "rust": return "rust"
        case "ts", "typescript": return "typescript"
        case "shell", "bash", "sh": return "bash"
        default: return language
        }
    }
}

struct CodeView: View {
    let text: String
    let code: String
    let language: String
    @State private var highlightedCode: NSAttributedString? = nil
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ScrollView(.horizontal) {
            Text(AttributedString(highlightedCode ?? NSAttributedString(string: code)))
                .font(.system(.body, design: .monospaced))
                .lineSpacing(4)
                .padding(8)
                .textSelection(.enabled)
                .onAppear(perform: highlightCode)
        }
    }
    
    func highlightCode() {
        let normalizedLanguage = normalizeLanguage(language)
        
        if let highlighter = Highlighter() {
            let theme = colorScheme == .dark ? "dark-github" : "xcode"
            highlighter.setTheme(theme)
            
            if let highlighted = highlighter.highlight(code, as: normalizedLanguage) {
                DispatchQueue.main.async {
                    highlightedCode = highlighted
                }
            }
        }
    }
    
    private func normalizeLanguage(_ language: String) -> String {
        switch language {
        case "py", "python": return "python"
        case "js", "javascript": return "javascript"
        case "swift": return "swift"
        case "java": return "java"
        case "cpp", "c++": return "cpp"
        case "cs", "csharp": return "csharp"
        case "rb", "ruby": return "ruby"
        case "go": return "go"
        case "rs", "rust": return "rust"
        case "ts", "typescript": return "typescript"
        case "shell", "bash", "sh": return "bash"
        default: return language
        }
    }
}

struct MessageInputView: View {
    @ObservedObject var chatStore: ChatStore
    let sendMessage: () -> Void

    var body: some View {
        HStack {
            TextField("Type a message...", text: $chatStore.messageInput)
                .padding()
                .background(Color(NSColor.systemGray.withAlphaComponent(0.3)))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(NSColor.systemGray.withAlphaComponent(0.2)), lineWidth: 0.5)
                )
                .submitLabel(.send)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(16)
            }
            .disabled(chatStore.isLoading || chatStore.messageInput.isEmpty)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}

@MainActor // Mark ChatDetailView as MainActor for Swift 6 concurrency safety
struct ChatDetailView: View {
    @ObservedObject var chatStore: ChatStore
    @Binding var chat: Chat
    @State private var newTitle: String
    
    init(chatStore: ChatStore, chat: Binding<Chat>) {
        self.chatStore = chatStore
        self._chat = chat
        _newTitle = State(wrappedValue: chat.wrappedValue.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Select Model", selection: $chatStore.selectedModel) {
                ForEach(chatStore.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .padding()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(chat.messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id) // Ensure each message has an ID for scrolling
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onAppear {
                    // Initial scroll to bottom when view appears
                    if let lastMessageId = chat.messages.last?.id {
                        proxy.scrollTo(lastMessageId, anchor: .bottom)
                    }
                    // Generate initial intelligent name suggestion
                    Task {
                        await updateChatTitle()
                    }
                }
            }

            MessageInputView(chatStore: chatStore, sendMessage: {
                sendMessage(proxy: scrollProxy)
            })
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                TextField("Chat Title", text: $newTitle)
                    .onSubmit {
                        chat.title = newTitle
                        chatStore.updateChat(chat: chat)
                    }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // Store the scroll proxy
    @State private var scrollProxy: ScrollViewProxy?
    
    // Updated PreferenceKey to be concurrency-safe in Swift 6
    private struct ScrollViewProxyKey: @preconcurrency PreferenceKey {
        // Mark defaultValue as static and immutable (no mutation needed)
        @MainActor static let defaultValue: ScrollViewProxy? = nil
        
        static func reduce(value: inout ScrollViewProxy?, nextValue: () -> ScrollViewProxy?) {
            value = nextValue()
        }
    }

    private func updateChatTitle() async {
        do {
            if let intelligentName = try await chatStore.generateIntelligentNameSuggestion(for: chat, selectedModel: chatStore.selectedModel) {
                await MainActor.run {
                    newTitle = intelligentName
                    chat.nameSuggestion = intelligentName
                    chat.title = intelligentName
                    chatStore.updateChat(chat: chat) // Ensure the store updates and notifies
                }
            }
        } catch {
            print("Error generating intelligent name: \(error)")
        }
    }

    private func sendMessage(proxy: ScrollViewProxy?) {
        guard !chatStore.messageInput.isEmpty, !chatStore.selectedModel.isEmpty else { return }

        let prompt = chatStore.messageInput
        let userMessage = Message(content: chatStore.messageInput, isUser: true)
        chat.messages.append(userMessage)
        chatStore.messageInput = ""
        chatStore.isLoading = true
        
        // Scroll to bottom after adding user message
        if let lastMessageId = chat.messages.last?.id, let proxy = proxy {
            withAnimation {
                proxy.scrollTo(lastMessageId, anchor: .bottom)
            }
        }

        Task {
            // Move async operations outside defer
            do {
                defer { chatStore.isLoading = false }
                
                guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
                    print("Invalid URL for Ollama API generate endpoint")
                    return
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "model": chatStore.selectedModel,
                    "prompt": prompt,
                    "stream": false
                ]
                
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    print("Invalid response from Ollama API")
                    return
                }
                
                let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
                let aiMessage = Message(content: ollamaResponse.response, isUser: false)
                
                await MainActor.run {
                    self.chat.messages.append(aiMessage)
                    self.chatStore.updateChat(chat: self.chat)
                    
                    // Scroll to bottom after AI response
                    if let lastMessageId = self.chat.messages.last?.id, let proxy = self.scrollProxy {
                        withAnimation {
                            proxy.scrollTo(lastMessageId, anchor: .bottom)
                        }
                    }
                    
                    // Update chat title after new message
                    Task {
                        await updateChatTitle()
                    }
                }
            } catch {
                print("Error sending message: \(error)")
            }
        }
    }
}

// Test View to Verify Syntax Highlighting
struct SyntaxHighlightTestView: View {
    var body: some View {
        VStack {
            Text("Syntax Highlighting Test for Python")
                .font(.title2)
                .padding()
            
            CodeView(
                text: "```python\ndef factorial(n):\n    if n == 0 or n == 1:\n        return 1\n    else:\n        return n * factorial(n - 1)\n\n# Example usage:\nnumber = 5\nprint(f\"The factorial of {number} is: {factorial(number)}\")\n```",
                code: "def factorial(n):\n    if n == 0 or n == 1:\n        return 1\n    else:\n        return n * factorial(n - 1)\n\n# Example usage:\nnumber = 5\nprint(f\"The factorial of {number} is: {factorial(number)}\")",
                language: "python"
            )
            .padding()
            
            Spacer()
        }
    }
}

// Preview Provider for Testing
struct SyntaxHighlightTestView_Previews: PreviewProvider {
    static var previews: some View {
        SyntaxHighlightTestView()
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")
        SyntaxHighlightTestView()
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
    }
}
