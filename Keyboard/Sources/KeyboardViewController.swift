import UIKit

/// Jev 键盘：一个「回复面板」键盘，不是打字键盘。
///
/// 交互闭环（不跳出聊天 App）：
///   ① 在聊天里长按对方消息 → 复制
///   ② 键盘上点「分析剪贴板」→ 意图/风险 + 每话术 2 条候选
///   ③ 点候选 → 直接 insertText 进当前输入框（发送永远由用户手动完成）
///
/// 联网、读剪贴板、读共享配置都要求用户在系统设置里给「允许完全访问」——
/// 这是 iOS 键盘扩展的唯一开关，没有别的权限可申请。
final class KeyboardViewController: UIInputViewController {

    private var language: JevLanguage { JevStore.loadLanguage() }

    private func L(_ zh: String, _ en: String) -> String {
        jevLocalized(language, zh: zh, en: en)
    }

    private enum Mode { case gate, idle, tones, loading, result, error }

    private var mode: Mode = .idle
    private var lastSource: Source = .clipboard
    private var lastMessage: String = ""
    private var lastContext: String?
    private var analysis: Analysis?
    private var errorText: String = ""
    private var stageLabel = UILabel()

    private enum Source { case clipboard, inputField, live }

    /// 直播模式：广播扩展持续录屏 + 本地 OCR，快照放 App Group。
    /// 快照新鲜且有待回消息时，待机页顶部多一个「读屏幕分析」主按钮，
    /// 用户就不再需要长按复制每条消息。
    private var liveTimer: Timer?
    /// 上次轮询时的直播状态签名，变了才重画待机页（内容级，不是时间级）
    private var lastLiveSignature = ""
    /// 面板高度占整屏比例（广播扩展据此抬底部裁剪，防键盘自身被 OCR 进快照）
    private var panelFraction: Double = 0

    /// 直播目标的签名：监听态 + 主目标文本 + 累积历史条数。
    /// 用内容而不是「是否 actionable」做签名——主目标文本一变（对方发新消息/用户滚到新片段）
    /// 按钮就要跟上，但聊天滚动造成的空帧不能把按钮打没了又弹回来（2026-10-22 用户实测的「跳一下」）。
    private static func liveSignature() -> String {
        let snap = JevLiveStore.load()
        let primary = snap?.latestIncoming ?? snap?.recent.first
        return "\(JevLiveStore.isListening)|\(primary ?? "-")|\(snap?.recent.count ?? 0)"
    }

    // MARK: 布局骨架

    private let topBar = UIView()
    private var statusLabel = UILabel()
    private let contentStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    /// 当前状态里参与「按内容定高」的块，顺序即纵向顺序。
    /// 候选区放的是内部列表（list）而不是滚动视图（scroll）——滚动视图没有固有高度，
    /// 量它会得到 0，面板就会被算矮、候选被压没。
    private var fitBlocks: [UIView] = []
    private var lastFit: (mode: Mode, width: CGFloat)?
    /// 反馈要落在当前页面的那行小字上（结果页是脚注，初始页是顶部提示行）
    private weak var flashTarget: UILabel?
    /// 系统容器比我们视图高出的那一截（露出来就是顶部那条「色块」）；每次出现只量一次
    private var containerGap: CGFloat = 0
    private var didMeasureContainerGap = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 面板底色交给系统，不要自己设：这个视图本身就是 UIInputView（.keyboard 样式），
        // 系统会给它画与键盘容器同一套底材。之前用自定义的 KB.bg 盖掉了它，于是我们面板
        // 和键盘顶部露出的那层底衬颜色对不上，看着就像多了一条"灰带"。
        // 不设背景色后两边同源同色，深色模式也跟着系统走。
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        buildTopBar()
        buildContentStack()
        mode = hasFullAccess ? .idle : .gate
#if DEBUG
        // 自检探针：任何落到面板上的点按都记一笔，并报告命中的视图类型。
        // 用来区分「触摸压根没进来」和「进来了但没送到候选行」。
        let probe = UITapGestureRecognizer(target: self, action: #selector(diagProbe(_:)))
        probe.cancelsTouchesInView = false
        view.addGestureRecognizer(probe)
#endif
        render()
    }

#if DEBUG
    @objc private func diagProbe(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        let hit = view.hitTest(p, with: nil)
        JevStore.diag(String(format: "面板点按 (%.0f,%.0f) 命中=%@", p.x, p.y,
                             String(describing: type(of: hit ?? UIView())))
            + " 状态=\(mode)")
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        statusLabel.text = hasFullAccess ? L("Jev · 已连接", "Jev · Connected")
            : L("Jev · 需要完全访问", "Jev · Full Access required")
        render()
        // 回写状态：主 App「开始」页据此显示键盘是否已启用、是否给了完全访问
        JevStore.saveKeyboardStatus(KeyboardStatus(lastSeen: Date(), hasFullAccess: hasFullAccess))
        prewarm()
        // 直播快照轮询：快照由广播扩展在别的进程里写，键盘只在待机页关心它活没活。
        // 状态签名（监听态/主目标/历史条数）变化时重画——新消息到了按钮要跟上，
        // 但每 2 秒的常规心跳不能触发重画打断点按。
        lastLiveSignature = Self.liveSignature()
        if liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                // 顺手刷新面板高度上报的时间戳（扩展按 20 秒时效读取，断了上报就视为关闭）
                if let self { JevLiveStore.setKeyboardPanel(fraction: self.panelFraction) }
                self?.liveTick()
            }
        }
        // 刚出现时 frame 还没定，等键盘铺开后再量容器间隙
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.coverContainerGap()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        liveTimer?.invalidate()
        liveTimer = nil
        JevLiveStore.setKeyboardPanel(fraction: 0)   // 面板没了，扩展不用再抬底部裁剪
    }

    private func liveTick() {
        guard mode == .idle, independentSettings == nil else { return }
        let sig = Self.liveSignature()
        if sig != lastLiveSignature {
            lastLiveSignature = sig
            render()
        }
    }

    /// 预热生成层连接。实测同一条起草请求，第二次能从 ~1.9 秒降到 ~0.5 秒——
    /// 连接和模型服务都要热身。键盘一出现就用一个不消耗额度的 `GET /models` 把连接建起来，
    /// 结果直接丢掉（失败也无所谓，真分析时该走的路径照走）。
    private func prewarm() {
        guard hasFullAccess else { return }
        let g = KeyboardLocalConfig.effective().generation
        guard !g.key.isEmpty, !g.base.isEmpty else { return }
        let base = g.base.hasSuffix("/") ? String(g.base.dropLast()) : g.base
        guard let url = URL(string: base + "/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(g.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        view.layer.borderColor = KB.cardBorder.cgColor
        // 重建各状态视图以刷新动态色
        if mode == .idle || mode == .gate { render() }
    }

    // MARK: 顶栏：品牌 + 状态 + 系统键盘切换 + 删除

    private func buildTopBar() {
        let dot = UIView()
        dot.backgroundColor = hasFullAccess ? KB.riskColor(0) : .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel = KB.label(hasFullAccess ? L("Jev · 已连接", "Jev · Connected") : L("Jev · 需要完全访问", "Jev · Full Access required"),
                               font: .systemFont(ofSize: 12, weight: .medium), color: KB.secondaryText)

        let title = UIStackView(arrangedSubviews: [dot, statusLabel])
        title.axis = .horizontal
        title.spacing = 6
        title.alignment = .center

        let globe = KB.button("", icon: "globe")
        globe.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        NSLayoutConstraint.activate([
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 36),
        ])

        let backspace = KB.button("", icon: "delete.left")
        backspace.addTarget(self, action: #selector(deleteBackwardTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            backspace.widthAnchor.constraint(equalToConstant: 44),
            backspace.heightAnchor.constraint(equalToConstant: 36),
        ])

        topBar.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        let settings = KB.button("", icon: "gearshape")
        settings.accessibilityLabel = "键盘独立设置"
        settings.addTarget(self, action: #selector(openIndependentSettings), for: .touchUpInside)
        settings.widthAnchor.constraint(equalToConstant: 36).isActive = true
        settings.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let hstack = UIStackView(arrangedSubviews: [UIView(), settings, globe, backspace])
        hstack.axis = .horizontal
        hstack.spacing = 8
        topBar.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 36),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hstack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            hstack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
        ])
    }

    private var independentSettings: KeyboardLocalSettingsView?

    @objc private func openIndependentSettings() {
        guard mode != .loading, independentSettings == nil else { return }
        let panel = KeyboardLocalSettingsView(fullAccess: hasFullAccess)
        independentSettings = panel
        panel.onClose = { [weak self, weak panel] in
            panel?.removeFromSuperview()
            guard let self else { return }
            self.independentSettings = nil
            self.mode = self.hasFullAccess ? .idle : .gate
            self.render()
        }
        view.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        lastFit = nil
        heightConstraint.constant = maxPanelHeight + containerGap
    }

    private func buildContentStack() {
        contentStack.axis = .vertical
        contentStack.spacing = 6
        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heightConstraint,
        ])
    }

    /// 面板高度按内容实测定，而不是把 320 写死。
    ///
    /// 写死一个高度 + UIStackView 默认的 .fill：多余的垂直空间会被平分下去，卡片被拉伸出
    /// 一大片空白（卡片底色和键盘底色几乎一样白，看着就是"空白太多"），该占空间的候选滚动区
    /// 反被挤成一条（"就只有一个东西"）。这里把各块在真实宽度下的高度加起来定高，190 起、470 封顶，
    /// 超出的部分才交给滚动。
    private func refit() {
        if independentSettings != nil { heightConstraint.constant = maxPanelHeight + containerGap; return }
        let avail = view.bounds.width - 24
        guard avail > 60, !fitBlocks.isEmpty else { return }
        var height: CGFloat = 6 + 36 + 6 + 8      // 上边距 + 顶栏 + 间距 + 下边距
        for (i, block) in fitBlocks.enumerated() {
            height += block.systemLayoutSizeFitting(
                CGSize(width: avail, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if i < fitBlocks.count - 1 { height += 6 }
        }
        heightConstraint.constant = min(max(height, Self.minPanelHeight), maxPanelHeight) + containerGap
    }

    /// 面板高度下限。**不能低于系统键盘的最小高度**：实测请求 190pt 时，系统按自己的最小值
    /// （约 204pt）给键盘区域，我们的视图只有 190 又被贴底，上方那 14pt 就露出系统的圆角底衬
    /// ——看起来就是键盘顶上多了一条灰带（结果态高度够大，所以不带这个问题）。
    private static let minPanelHeight: CGFloat = 210

    /// 键盘面板上方那条"灰带"的成因排查（结论：不是缝隙，量出来容器与视图**等高**）。
    /// 这段保留作兜底：万一某个 App/机型上容器真的比视图高，就把视图补到容器高度、用背景盖住。
    /// 关键点：**必须等 frame 铺开后再量**——刚出现时 frame 是整屏尺寸（390x844），
    /// 拿它算会得到 0 并误标"已量过"，于是永远不再量（上一版就是这么失效的）。
    private func coverContainerGap() {
        guard !didMeasureContainerGap, let container = view.superview else { return }
        let containerHeight = container.bounds.height
        let viewHeight = view.bounds.height
        guard containerHeight > 0, viewHeight > 0,
              containerHeight < 600, viewHeight < 600 else { return }  // 还没铺开，下次再看
        didMeasureContainerGap = true
        let gap = containerHeight - viewHeight
        guard gap > 1, gap <= 60 else { return }
        containerGap = gap
        lastFit = nil
        refit()
#if DEBUG
        JevStore.diag(String(format: "补容器间隙 %.0fpt（容器 %.0f / 视图 %.0f）",
                             gap, containerHeight, viewHeight))
#endif
    }

    /// 面板上限跟着屏幕走：小屏（SE 667pt）上写死 470 会盖掉大半个屏幕，
    /// 大屏（Pro Max 932pt）上又不该浪费空间。取可用高度的 45%，夹在 [220, 470] 之间。
    /// 用窗口场景的坐标系而不是 UIScreen.bounds——后者恒为竖屏尺寸，横屏时会算多。
    private var maxPanelHeight: CGFloat {
        let scene = view.window?.windowScene
        let available = scene?.coordinateSpace.bounds.height ?? UIScreen.main.bounds.height
        return min(470, max(220, available * 0.45))
    }

#if DEBUG
    private func frameText(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 上报面板高度比例：键盘一开聊天区底部就被面板盖住，扩展识别区必须同步抬高，
        // 否则键盘自己的按钮文字（含上一轮目标）会被 OCR 进快照形成自反馈回路
        let screenH = UIScreen.main.bounds.height
        if screenH > 0 {
            panelFraction = Double(view.bounds.height / screenH)
            JevLiveStore.setKeyboardPanel(fraction: panelFraction)
        }
        coverContainerGap()               // 铺开后如果容器比视图高，就补高盖住（通常量到的是等高）
        let width = view.bounds.width
        guard width > 0, lastFit == nil || lastFit!.mode != mode || lastFit!.width != width else { return }
        lastFit = (mode, width)
        refit()
#if DEBUG
        // 顶部那条「色块」的取证（1）：我们视图与直接父视图的几何关系
        let supFrame = view.superview.map { frameText($0.frame) } ?? "nil"
        let supBounds = view.superview.map { frameText($0.bounds) } ?? "nil"
        JevStore.diag("几何 view=\(frameText(view.frame)) 父frame=\(supFrame) 父bounds=\(supBounds) 兄弟数=\(view.superview?.subviews.count ?? -1)")

        // 取证（2）：等键盘真正铺开后再往上数三层容器——iOS 26 的键盘容器自己画圆角底衬，
        // 得知道那一层是什么类、多大、什么颜色，才能判断那条带子是它的还是我们的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            var node: UIView? = self.view
            for _ in 0..<4 {
                guard let cur = node else { break }
                let bg = cur.backgroundColor.map { "\($0)" } ?? "nil"
                parts.append("\(type(of: cur)) \(frameText(cur.frame)) bg=\(bg)")
                node = cur.superview
            }
            JevStore.diag("容器链 " + parts.joined(separator: " | "))
        }
#endif
    }

    @objc private func switchKeyboard() { advanceToNextInputMode() }

    @objc private func deleteBackwardTapped() {
        textDocumentProxy.deleteBackward()
    }

#if DEBUG
    /// 自检入口：把面板直接切到某个状态渲染出来。
    /// 键盘本体不走这条路径；这是给独立预览壳工程用的——键盘扩展没法用脚本唤起，
    /// 靠它才能在模拟器上按不同机型尺寸看布局（见 /tmp 的 PanelPreview 壳）。
    func previewPanel(_ kind: String, analysis: Analysis? = nil, errorText: String = "") {
        self.analysis = analysis
        self.errorText = errorText
        switch kind {
        case "gate": mode = .gate
        case "tones": mode = .tones
        case "loading": mode = .loading
        case "result": mode = .result
        case "error": mode = .error
        default: mode = .idle
        }
        render()
    }
#endif

    // MARK: 状态渲染

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fitBlocks = []
        lastFit = nil
        switch mode {
        case .gate: contentStack.addArrangedSubview(gateView())
        case .idle: contentStack.addArrangedSubview(idleView())
        case .tones: contentStack.addArrangedSubview(tonesView())
        case .loading: contentStack.addArrangedSubview(loadingView())
        case .result: contentStack.addArrangedSubview(resultView())
        case .error: contentStack.addArrangedSubview(errorView())
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        render()
    }

    // MARK: 门禁视图（没有完全访问时）

    private func gateView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("需要「允许完全访问」", "Full Access required"), font: .systemFont(ofSize: 16, weight: .bold),
                             color: .systemRed)
        let steps = KB.label(
            L("Jev 键盘要联网调用模型、读取剪贴板，这两项都要求完全访问：\n\n① 打开系统「设置」→「通用」→「键盘」→「键盘」\n② 点「添加新键盘」→ 选「Jev 键盘」\n③ 点「Jev 键盘」→ 打开「允许完全访问」\n\n完全访问意味着键盘能传输按键与剪贴板内容——本项目开源、只用你自己填的 API Key，不用时可以在同页一键移除。", "Jev needs Full Access to call the model and read the clipboard:\n\n① Open Settings → General → Keyboard → Keyboards\n② Tap Add New Keyboard → Jev Keyboard\n③ Select Jev Keyboard → turn on Full Access\n\nFull Access lets the keyboard transmit keystrokes and clipboard content. The project is open source and uses only the API key you provide; you can remove it anytime."),
            font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let vstack = UIStackView(arrangedSubviews: [title, steps])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 待机视图

    private func idleView() -> UIView {
        let cfg = KeyboardLocalConfig.effective()

        var rows: [UIView] = []
        let snap = JevLiveStore.load()
        let listening = JevLiveStore.isListening
        // 主目标 = 当前帧尾部的对方消息；当前帧没有时退回累积历史里最近的一条。
        // 键盘一弹聊天就滚到底、画面里可能只剩用户自己的消息——目标不能因此消失
        // 乱跳（2026-10-22 用户实测），也不能因此只能回最新一条（用户要能挑历史消息）。
        let primary = snap?.latestIncoming ?? snap?.recent.first
        if listening, let primary {
            // 目标列表：主目标（当前帧尾部；空帧时退回累积历史最近一条）+ 至多两条更早的。
            // 拆开写不死类型检查器：数组拼接 + dropFirst + filter + prefix 一口气写会炸。
            var targets: [String] = [primary]
            for older in (snap?.recent ?? []).dropFirst()
            where !LiveChatParser.areSameMessage(older, primary) && targets.count < 3 {
                targets.append(older)
            }
            for (index, message) in targets.enumerated() {
                let flattened = message.replacingOccurrences(of: "\n", with: " ")
                // 预览给到 ~34 字 + 两行折行：用户必须能分清按钮对应的是哪条消息
                //（2026-10-22 用户反馈 16 字截断「根本看不清楚回复哪一条内容，点不到」）
                let preview = String(flattened.prefix(34)) + (flattened.count > 34 ? "…" : "")
                let label = index == 0
                    ? L("读屏幕分析：「\(preview)」", "Read screen: \"\(preview)\"")
                    : L("回复更早：「\(preview)」", "Earlier: \"\(preview)\"")
                let btn = KB.button(label,
                                    icon: index == 0 ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath",
                                    primary: index == 0,
                                    font: .systemFont(ofSize: 13, weight: .semibold),
                                    wraps: true)
                btn.heightAnchor.constraint(equalToConstant: index == 0 ? 56 : 50).isActive = true
                // 目标文本放 identifier 里传给 action（同话术格子的做法）
                btn.accessibilityIdentifier = message
                btn.addTarget(self, action: #selector(analyzeTarget(_:)), for: .touchUpInside)
                rows.append(btn)
            }
        }

        // 三态提示：有可选目标（按钮在上方）/ 只在监听还没读到任何对方消息 / 未开播。
        // 「只在监听」这一态必须有明确反馈，否则开播后的键盘和平时长得一模一样，
        // 用户会以为功能没生效（2026-10-22 真机首试：用户看着普通待机页直接退出去找客服了）。
        let guide = KB.label(
            primary != nil ? L("直播监听中 · 免复制，点上面的按钮直接分析", "Live listening · no copy needed, tap a button above")
                           : listening ? L("直播监听中 · 还没读到对方的新消息，回到聊天界面停一两秒再回来",
                                           "Live listening · no new message from them yet. Stay in the chat a couple of seconds, then come back")
                           : L("长按对方消息 → 复制，再点下面的按钮", "Long-press the message → Copy, then tap a button below"),
            font: .systemFont(ofSize: 12), color: KB.secondaryText)

        let clipBtn = KB.button(L("分析剪贴板", "Analyze Clipboard"), icon: "doc.on.clipboard",
                                primary: primary == nil,
                                font: .systemFont(ofSize: 14, weight: .semibold))
        clipBtn.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)

        let inputBtn = KB.button(L("AI 分析输入框文字", "Analyze Input"), icon: "text.cursor",
                                 font: .systemFont(ofSize: 14, weight: .semibold))
        inputBtn.addTarget(self, action: #selector(analyzeInputField), for: .touchUpInside)

        // 两个分析入口并排：左边读剪贴板，右边读当前输入框；直播有目标时主色让位给读屏幕
        let btnRow = UIStackView(arrangedSubviews: [clipBtn, inputBtn])
        btnRow.axis = .horizontal
        btnRow.spacing = 8
        btnRow.distribution = .fillEqually
        btnRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // 话术：点进去直接在键盘上选（写回共享配置，App 的「话术」页看到的是同一份）
        let tonesBtn = KB.button(
            cfg.activeSlots.isEmpty
                ? L("话术：都没选（点这里选）", "Tones: none selected")
                : L("话术：", "Tones: ") + cfg.activeSlots.map { localizedToneName($0, language: language) }.joined(separator: " · "),
            icon: "theatermasks")
        tonesBtn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        tonesBtn.addTarget(self, action: #selector(openTonePicker), for: .touchUpInside)

        // 待机页**不放**发送键：这一页还没有候选，没有可发的东西；而输入框一旦有字，
        // 宿主 App 自己的发送按钮就出来了，
        // 键盘下方再挂一个只是添乱。发送键只在结果页——点完候选、手还在面板上时用。
        rows.append(guide)
        rows.append(btnRow)
        rows.append(tonesBtn)
        let vstack = UIStackView(arrangedSubviews: rows)
        vstack.axis = .vertical
        vstack.spacing = 8
        if JevDraft(cfg: cfg).isConfigured {
            // 配置完整时不占行
        } else {
            let warn = KB.label(L("⚠️ 还没配置生成层：点右上角齿轮设置键盘独立配置", "⚠️ Generation is not configured: tap the gear to configure this keyboard"),
                                font: .systemFont(ofSize: 12), color: .systemOrange, lines: 0)
            vstack.addArrangedSubview(warn)
        }
        fitBlocks = [vstack]
        return vstack
    }

    // MARK: 话术选择视图（直接在键盘上配）

    @objc private func openTonePicker() { setMode(.tones) }

    /// 话术选择：内置 + 自定义全列出来，点一下选中/取消，最多 3 个槽。
    /// 每次从共享配置重新读（App 那边改过也能立刻看到），选中即落盘，下一次分析就生效。
    private func tonesView() -> UIView {
        let cfg = KeyboardLocalConfig.effective()
        let names = orderedToneNames(custom: cfg.customTones)
        let active = cfg.activeSlots

        let title = KB.label(L("选话术（最多 \(MAX_SLOTS) 个 · 每个每次出 2 条）", "Choose tones (up to \(MAX_SLOTS) · 2 suggestions each)"),
                             font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0)
        var blocks: [UIView] = [title]

        // 每行 3 个等宽格子：话术名长短不一，等宽比按内容排更好点、也更整齐
        var row: [UIButton] = []
        for name in names {
            let btn = KB.button(localizedToneName(name, language: language), primary: active.contains(name),
                                font: .systemFont(ofSize: 13, weight: .medium))
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            btn.accessibilityIdentifier = name
            btn.addTarget(self, action: #selector(toneChipTapped(_:)), for: .touchUpInside)
            row.append(btn)
            if row.count == 3 {
                blocks.append(gridRow(row))
                row = []
            }
        }
        if !row.isEmpty {
            // 补齐到 3 个：不加空位的话，最后一行的单个话术会被 .fillEqually 拉成整行宽
            var cells: [UIView] = row
            while cells.count < 3 { cells.append(UIView()) }
            blocks.append(gridRow(cells))
        }

        let done = KB.button(L("好了", "Done"), icon: "checkmark", primary: true)
        done.heightAnchor.constraint(equalToConstant: 36).isActive = true
        done.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        blocks.append(done)

        let outer = UIStackView(arrangedSubviews: blocks)
        outer.axis = .vertical
        outer.spacing = 6
        fitBlocks = blocks
        return outer
    }

    private func gridRow(_ cells: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: cells)
        s.axis = .horizontal
        s.spacing = 6
        s.distribution = .fillEqually
        return s
    }

    @objc private func toneChipTapped(_ sender: UIButton) {
        guard let name = sender.accessibilityIdentifier else { return }
        var cfg = KeyboardLocalConfig.effective()
        var slots = cfg.slots
        while slots.count < MAX_SLOTS { slots.append(NONE_LABEL) }
        if let i = slots.firstIndex(of: name) {
            slots[i] = NONE_LABEL                      // 再点一下 = 取消
        } else if let free = slots.firstIndex(where: { $0.isEmpty || $0 == NONE_LABEL }) {
            slots[free] = name                         // 填进第一个空槽
        } else {
            slots[MAX_SLOTS - 1] = name                // 槽满了就顶掉最后一个
        }
        cfg.slots = Array(slots.prefix(MAX_SLOTS))
        do {
            try KeyboardLocalConfig.saveEffective(cfg)
        } catch {
            errorText = L("保存话术失败，请在键盘独立设置中重试。", "Could not save tones. Retry in keyboard settings.")
            setMode(.error)
            return
        }
        render()                                       // 重画刷新高亮
    }

    // MARK: 加载视图

    private func loadingView() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stageLabel = KB.label(L("分析中…", "Analyzing…"), font: .systemFont(ofSize: 14), color: KB.secondaryText)
        let hstack = UIStackView(arrangedSubviews: [spinner, stageLabel])
        hstack.axis = .horizontal
        hstack.spacing = 10
        hstack.alignment = .center
        let card = KB.cardView()
        card.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            hstack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 96),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 结果视图

    private func resultView() -> UIView {
        guard let a = analysis else { return UIView() }
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 5

        // 判断头
        let header = KB.cardView()
        var headerItems: [UIView] = []
        if let jr = a.judge {
            // 风险等级文案跟徽章同一行——它单独占一行太浪费高度（键盘面板寸土寸金）
            let riskText = KB.label(localizedRiskLabel(jr.risk, language: language), font: .systemFont(ofSize: 12),
                                    color: KB.riskColor(jr.risk), lines: 1)
            riskText.setContentHuggingPriority(.required, for: .horizontal)
            let chipRow = UIStackView(arrangedSubviews: [
                KB.badge(localizedIntent(jr.intent, language: language), color: KB.brand),
                KB.badge(L(String(format: "风险 %.0f/9", jr.risk), String(format: "Risk %.0f/9", jr.risk)), color: KB.riskColor(jr.risk)),
                riskText,
                UIView(),   // 占位：吃掉余量，徽章和文案各自按内容 hug
            ])
            chipRow.axis = .horizontal
            chipRow.spacing = 8
            headerItems.append(chipRow)
            if !jr.actions.isEmpty {
                headerItems.append(KB.label(L("建议：", "Next: ") + localizedActions(jr.actions, language: language).joined(separator: " · "),
                                            font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0))
            }
        } else {
            headerItems.append(KB.label(L("未配置判断层，直接生成（可在 App 里开启）", "Judge not configured; drafting directly (enable it in the app)"),
                                        font: .systemFont(ofSize: 12), color: KB.secondaryText))
        }
        let quoted = KB.label("「" + (a.message.count > 40 ? String(a.message.prefix(40)) + "…" : a.message) + "」",
                              font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 1)
        headerItems.append(quoted)
        let hstack = UIStackView(arrangedSubviews: headerItems)
        hstack.axis = .vertical
        hstack.spacing = 4
        hstack.isLayoutMarginsRelativeArrangement = true
        hstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        header.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: header.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        outer.addArrangedSubview(header)

        // 时间脚注（先建好：插入/发送的反馈要临时改它）
        let footer = KB.label(a.rankingPending
                                ? L("候选已出 · 排序中…（现在就能点）", "Suggestions ready · ranking… (you can tap now)")
                                : L(String(format: "%.1f 秒 · 点候选插入，点「发送」发出", a.elapsed), String(format: "%.1f s · tap a suggestion to insert, then Send", a.elapsed)),
                              font: .systemFont(ofSize: 10), color: KB.secondaryText)
        flashTarget = footer

        // 候选列表（可滚动）。真没有候选时也要说一句话，别留给用户一片空白。
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        if a.candidates.isEmpty {
            list.addArrangedSubview(KB.label(L("这次没出候选，点「换一批」再试一次", "No suggestions this time. Tap Regenerate to try again."),
                                             font: .systemFont(ofSize: 13),
                                             color: KB.secondaryText, lines: 0))
        }
        for c in a.candidates {
            let row = CandidateRow(candidate: c)
            row.onInsert = { [weak self] candidate in
                guard let self else { return }
#if DEBUG
                JevStore.diag("准备插入：话术=\(candidate.tone) 字数=\(candidate.text.count)")
#endif
                self.textDocumentProxy.insertText(candidate.text)
#if DEBUG
                let ctx = self.textDocumentProxy.documentContextBeforeInput ?? "<拿不到>"
                JevStore.diag("插入后输入框尾部=「\(ctx.suffix(24))」")
#endif
                self.flashFooter(self.L("已插入 · 点「发送」发出", "Inserted · tap Send to submit"), color: KB.riskColor(0))
            }
            list.addArrangedSubview(row)
        }
        for n in a.notices.prefix(2) {
            list.addArrangedSubview(KB.label("· " + n, font: .systemFont(ofSize: 11),
                                             color: .systemOrange, lines: 0))
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        // 别让滚动视图拖延把触摸交给候选行——延迟投递正是"点了没反应"的常见来源
        scroll.delaysContentTouches = false
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        outer.addArrangedSubview(scroll)

        // 底部操作：发送挪到右下角，左边留给换一批/返回
        let send = KB.button(L("发送", "Send"), icon: "paperplane.fill", primary: true)
        send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        send.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let regen = KB.button(L("换一批", "Regenerate"), icon: "arrow.clockwise")
        regen.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [regen, close, UIView(), send])
        actions.axis = .horizontal
        actions.spacing = 8
        outer.addArrangedSubview(actions)
        outer.addArrangedSubview(footer)

        // 只让候选区伸缩：卡片/按钮都按内容 hug，否则会被多余的垂直空间拉出空白。
        header.setContentHuggingPriority(.required, for: .vertical)
        actions.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        fitBlocks = [header, list, actions, footer]
        return outer
    }

    /// 即时反馈：目标那行小字短暂变色改字。用户要一眼能确认「点到了 / 插进去了 / 发出去了」。
    private func flashFooter(_ text: String, color: UIColor) {
        guard let target = flashTarget else { return }
        let base = target.text
        target.textColor = color
        target.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak target] in
            target?.textColor = KB.secondaryText
            target?.text = base
        }
    }

    /// 发送。键盘扩展**点不了宿主 App 的发送按钮**（iOS 没这个 API），唯一能用的杠杆是插一个换行：
    /// 对「把回车当发送」的聊天 App 有效（输入框是文本视图、在 shouldChangeTextInRange 里拦换行的那些），
    /// 对单行输入框无效。所以发完回读输入框，按实际结果如实反馈，不假装成功。
    @objc private func sendMessage() {
        guard hasFullAccess else { setMode(.gate); return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText("\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let after = self.textDocumentProxy.documentContextBeforeInput ?? ""
            if before.isEmpty && after.isEmpty {
                self.flashFooter(self.L("输入框是空的：先点一条候选", "The input is empty: tap a suggestion first"), color: .systemOrange)
            } else if after.isEmpty {
                self.flashFooter(self.L("已发送 ✓", "Sent ✓"), color: KB.riskColor(0))
            } else {
                self.flashFooter(self.L("这个 App 不吃键盘换行，请点它的发送按钮", "This app does not send on Return; tap its Send button"), color: .systemOrange)
            }
        }
    }

    // MARK: 错误视图

    private func errorView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("出错了", "Something went wrong"), font: .systemFont(ofSize: 15, weight: .bold), color: .systemRed)
        let body = KB.label(errorText, font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let retry = KB.button(L("重试", "Retry"), icon: "arrow.clockwise")
        retry.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let btns = UIStackView(arrangedSubviews: [retry, close])
        btns.axis = .horizontal
        btns.spacing = 8
        let vstack = UIStackView(arrangedSubviews: [title, body, btns])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 动作

    @objc private func analyzeClipboard() {
        lastSource = .clipboard
        guard hasFullAccess else { setMode(.gate); return }
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = L("剪贴板是空的。先在聊天里长按要回的消息 →「复制」，再回来点分析。", "The clipboard is empty. Long-press a message in your chat, copy it, then tap Analyze.")
            setMode(.error)
            return
        }
        if let data = text.data(using: .utf8),
           (try? JSONDecoder().decode(JevConfig.self, from: data)) != nil {
            errorText = L("剪贴板是包含 Key 的模型配置，请先在齿轮设置中导入，再复制聊天消息。", "The clipboard contains model credentials. Import them in Settings, then copy a chat message.")
            setMode(.error)
            return
        }
        run(message: text, context: nil)
    }

    @objc private func analyzeInputField() {
        lastSource = .inputField
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let text = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = L("输入框里没有文字。这个按钮分析的是当前输入框里已输入的内容（比如你打了一半拿不准的话）。", "The input is empty. This button analyzes text already typed in the field.")
            setMode(.error)
            return
        }
        run(message: text, context: nil)
    }

    /// 直播模式入口：不读剪贴板，读广播扩展 OCR 出来的对话快照。
    /// 目标文本（当前帧尾部对方消息，或用户挑的「更早的消息」）放在按钮的
    /// accessibilityIdentifier 里传入（同话术格子的做法）；context = 之前的对话——
    /// 和剪贴板路径走同一条管线。
    @objc private func analyzeTarget(_ sender: UIButton) {
        lastSource = .live
        guard hasFullAccess else { setMode(.gate); return }
        guard let message = sender.accessibilityIdentifier, !message.isEmpty else { return }
        run(message: message, context: JevLiveStore.load()?.contextText)
    }

    @objc private func regenerate() { run(message: lastMessage, context: lastContext) }
    @objc private func backToIdle() { setMode(.idle) }

    private func run(message: String, context: String?) {
        lastMessage = message
        lastContext = context
        setMode(.loading)
        stageLabel.text = L("判断中…", "Judging…")
        let pipeline = JevPipeline(cfg: KeyboardLocalConfig.effective())

        Task { @MainActor [weak self] in
            let analysis = await pipeline.analyze(
                message: message, context: context,
                onStage: { [weak self] stage in
                    Task { @MainActor in
                        switch stage {
                        case .judging: self?.stageLabel.text = self?.L("判断中…", "Judging…")
                        case .drafting(let done, let total):
                            self?.stageLabel.text = self?.L("生成中 \(done)/\(total)…", "Drafting \(done)/\(total)…")
                        case .ranking: self?.stageLabel.text = self?.L("排序中…", "Ranking…")
                        case .done: self?.stageLabel.text = self?.L("完成", "Done")
                        }
                    }
                },
                onPartial: { [weak self] partial in
                    // 第一条话术的候选一到就先出面板，不等其余话术、更不等排序。
                    // 用消息文本挡一下，别让上一轮的迟到结果盖掉新一轮。
                    Task { @MainActor in
                        guard let self, self.lastMessage == partial.message else { return }
                        self.analysis = partial
                        self.setMode(.result)
                    }
                })
            guard let self else { return }
            self.analysis = analysis
            if let fatal = analysis.fatalError {
                self.errorText = fatal
                self.setMode(.error)
            } else {
                self.setMode(.result)
            }
        }
    }
}
