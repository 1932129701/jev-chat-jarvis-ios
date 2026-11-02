import UIKit
import Security

/// Extension-only credentials. No shared access group is requested.
enum KeyboardLocalConfig {
    private static let service = "jev.keyboard.independent-config.v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "configuration"]
    }

    static func read() throws -> JevConfig? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try JSONDecoder().decode(JevConfig.self, from: data)
    }

    static func save(_ config: JevConfig) throws {
        let data = try JSONEncoder().encode(config)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func effective() -> JevConfig {
        if let local = try? read() { return local }
        return JevStore.loadConfig()
    }

    static func saveEffective(_ config: JevConfig) throws {
        if try read() != nil { try save(config) }
        else { JevStore.saveConfig(config) }
    }
}

/// A keyboard extension cannot summon another system keyboard for its own fields.
/// Each field is filled only by an explicit Paste tap; secrets never enter the host input.
final class KeyboardLocalSettingsView: UIView {
    var onClose: (() -> Void)?
    private var draft: JevConfig
    private let stack = UIStackView()
    private let message = UILabel()
    private let fullAccess: Bool

    init(fullAccess: Bool) {
        self.fullAccess = fullAccess
        draft = KeyboardLocalConfig.effective()
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        let scroll = UIScrollView()
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)
        ])
        addText("键盘独立设置", bold: true)
        addText("配置仅用于此键盘，保存后优先于主 App。先复制一个值，再点对应的“粘贴”。可切换其他键盘输入、复制后切回。Key 不会写进聊天输入框。直播共享仍需要有效 App Group。")
        addButton("关闭（未保存的修改将丢弃）") { [weak self] in self?.onClose?() }
        if !fullAccess { addText("请先在系统设置中开启 Jev 键盘的“允许完全访问”，再粘贴配置和联网。") }
        do {
            addText(try KeyboardLocalConfig.read() == nil ? "当前：主 App 配置（尚无独立配置）" : "当前：键盘独立配置")
        } catch { addText("读取独立配置失败：\((error as NSError).code)。可尝试清除后重新设置。") }
        addButton("从主 App 导入剪贴板配置（含 Key）") { [weak self] in
            guard let self else { return }
            guard self.fullAccess else { self.message.text = "请先开启允许完全访问。"; return }
            guard let text = UIPasteboard.general.string, text.utf8.count <= 131072,
                  let data = text.data(using: .utf8),
                  let imported = try? JSONDecoder().decode(JevConfig.self, from: data) else {
                self.message.text = "请先在主 App 的模型页复制配置，再于 60 秒内导入。"; return
            }
            self.draft = imported
            // Clear only the value just consumed, never overwrite a newer clipboard item.
            if UIPasteboard.general.string == text { UIPasteboard.general.items = [] }
            self.refresh()
            self.message.text = "已导入，请点底部保存。导入不会自动发送网络请求。"
        }
        addText("生成层（必配）", bold: true)
        for preset in ProviderPreset.all where preset.id != "custom" && preset.id != "ollama" {
            addButton(preset.name) { [weak self] in
                guard let self else { return }
                self.draft.genBase = preset.base
                self.draft.genModel = preset.model
                self.draft.genKind = preset.kind
                self.draft.genKey = ""
                self.draft.genExtraJSON = ""
                self.refresh()
                self.message.text = "已选择生成服务，请粘贴该服务的 Key。"
            }
        }
        addButton("切换 OpenAI / Anthropic 格式") { [weak self] in
            guard let self else { return }
            self.draft.genKind = self.draft.genKind == .openai ? .anthropic : .openai
            self.refresh()
        }
        field("genBase", title: "生成地址", get: { $0.genBase }, set: { $0.genBase = $1 })
        field("genModel", title: "生成模型", get: { $0.genModel }, set: { $0.genModel = $1 })
        field("genKey", title: "生成 Key", secret: true, get: { $0.genKey }, set: { $0.genKey = $1 })
        field("genExtraJSON", title: "额外 JSON（可选）", get: { $0.genExtraJSON }, set: { $0.genExtraJSON = $1 })
        addText("判断层（可选，留空 Key 时只生成候选）", bold: true)
        addButton("博查 Jev") { [weak self] in
            self?.draft.judgeBase = "https://jev.bocha.cn"
            self?.draft.judgeModel = "bocha-jev-v1"
            self?.draft.judgeKey = ""
            self?.refresh()
        }
        for preset in JudgePreset.all where preset.id != "custom" {
            addButton(preset.name) { [weak self] in
                self?.draft.judgeBase = preset.base
                self?.draft.judgeModel = preset.model
                self?.draft.judgeKey = ""
                self?.refresh()
            }
        }
        field("judgeBase", title: "判断地址", get: { $0.judgeBase }, set: { $0.judgeBase = $1 })
        field("judgeModel", title: "判断模型", get: { $0.judgeModel }, set: { $0.judgeModel = $1 })
        field("judgeKey", title: "判断 Key", secret: true, get: { $0.judgeKey }, set: { $0.judgeKey = $1 })
        message.numberOfLines = 0
        message.font = .systemFont(ofSize: 13)
        message.textColor = .systemOrange
        stack.addArrangedSubview(message)
        addButton("保存并使用独立配置") { [weak self] in self?.save() }
        addButton("清除独立配置，恢复读取主 App") { [weak self] in
            guard let self else { return }
            do {
                try KeyboardLocalConfig.clear()
                self.onClose?()
            } catch { self.message.text = "清除失败：\((error as NSError).code)" }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addText(_ text: String, bold: Bool = false) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: bold ? 16 : 12, weight: bold ? .bold : .regular)
        stack.addArrangedSubview(label)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.titleLabel?.numberOfLines = 0
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    private func field(_ id: String, title: String, secret: Bool = false,
                       get: @escaping (JevConfig) -> String,
                       set: @escaping (inout JevConfig, String) -> Void) {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 12)
        // Display closure is retained by an action; refresh invokes these without reading clipboard.
        label.accessibilityIdentifier = id
        stack.addArrangedSubview(label)
        let update = { [weak self, weak label] in
            guard let self else { return }
            let value = get(self.draft)
            label?.text = title + "：" + (secret ? (value.isEmpty ? "未配置" : "已填写（隐藏）") : value)
            if id == "genBase" { label?.text = "格式：\(self.draft.genKind.rawValue)\n" + (label?.text ?? "") }
        }
        refreshers.append(update)
        addButton("粘贴“\(title)”") { [weak self] in
            guard let self else { return }
            guard self.fullAccess else { self.message.text = "请先开启允许完全访问。"; return }
            guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                self.message.text = "剪贴板为空或不是文本。"; return
            }
            set(&self.draft, text)
            update()
            self.message.text = "已填入\(title)，请保存。"
        }
        addButton("清空“\(title)”") { [weak self] in
            guard let self else { return }
            set(&self.draft, "")
            update()
        }
    }

    private var refreshers: [() -> Void] = []
    private func refresh() { refreshers.forEach { $0() } }

    private func save() {
        guard fullAccess else { message.text = "请先开启允许完全访问。"; return }
        guard !draft.genKey.isEmpty, !draft.genModel.isEmpty else {
            message.text = "请填写生成层的 Key 和模型。"; return
        }
        func validHTTPS(_ text: String) -> Bool {
            guard let url = URL(string: text) else { return false }
            return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
        }
        guard validHTTPS(draft.genBase), draft.judgeKey.isEmpty || (validHTTPS(draft.judgeBase) && !draft.judgeModel.isEmpty) else {
            message.text = "请填写有效的 HTTPS 服务地址；启用判断层时也需要模型。"; return
        }
        if !draft.genExtraJSON.isEmpty {
            guard let data = draft.genExtraJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                message.text = "额外 JSON 必须是 JSON 对象。"; return
            }
        }
        do {
            try KeyboardLocalConfig.save(draft)
            onClose?()
        } catch { message.text = "保存失败：\((error as NSError).code)。请检查键盘签名的钥匙串权限。" }
    }
}
