import SwiftUI

struct TranslationSettingsView: View {
    @AppStorage(TranslationService.providerKey) private var provider = "google"
    @AppStorage(TranslationService.baseURLKey) private var baseURL = "https://api.deepseek.com"
    @AppStorage(TranslationService.modelKey) private var model = "deepseek-flash"
    @AppStorage(TranslationService.targetKey) private var targetLanguage = "zh-CN"
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var testMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("翻译服务", selection: $provider) {
                    Text("Google 免费翻译").tag("google")
                    Text("DeepSeek API").tag("deepseek")
                    Text("其他 OpenAI 兼容 API").tag("custom")
                }
                Picker("目标语言", selection: $targetLanguage) {
                    Text("简体中文").tag("zh-CN")
                    Text("繁体中文").tag("zh-TW")
                    Text("日语").tag("ja")
                    Text("英语").tag("en")
                }
            } header: {
                Text("基本设置")
            } footer: {
                Text("Google 使用公开的非官方免费接口，可能存在限流或服务变更。DeepSeek 和自定义 API 由你自己的 API Key 计费。")
            }

            if provider != "google" {
                Section("API 配置") {
                    if provider == "deepseek" {
                        LabeledContent("服务商", value: "DeepSeek")
                        TextField("API Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("模型名称", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("API Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("模型名称", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("API Key 仅保存到本机 iOS 钥匙串，不会上传到 itchPocket 或 GitHub。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("保存 API 配置") {
                        saveKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("连接测试") {
                Button {
                    Task { await testTranslation() }
                } label: {
                    HStack {
                        if isTesting { ProgressView() }
                        Text(isTesting ? "正在测试…" : "测试翻译服务")
                    }
                }
                .disabled(isTesting || (provider != "google" && (apiKey.isEmpty && (KeychainStore.read("translation.apiKey") ?? "").isEmpty)))
                if let testMessage {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(testMessage.hasPrefix("成功") ? .green : .secondary)
                }
            }
        }
        .navigationTitle("翻译设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = KeychainStore.read("translation.apiKey") ?? ""
        }
    }

    private func saveKey() {
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.delete("translation.apiKey")
            } else {
                try KeychainStore.save(trimmed, for: "translation.apiKey")
            }
            testMessage = "API 配置已保存。"
        } catch {
            testMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func testTranslation() async {
        if provider != "google" && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveKey()
        }
        isTesting = true
        testMessage = nil
        defer { isTesting = false }
        do {
            let result = try await TranslationService.translate("A small test for game description translation.")
            testMessage = "成功：\(result)"
        } catch {
            testMessage = "测试失败：\(error.localizedDescription)"
        }
    }
}
