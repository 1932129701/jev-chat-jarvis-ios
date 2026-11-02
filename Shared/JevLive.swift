import Foundation
import Vision
import CoreVideo
import Accelerate

// MARK: - 直播模式（实验分支）：录屏 → 本地 OCR → 解析对话 → 免复制出候选
//
// 数据流：广播扩展（JevLive）每 2 秒取一帧 → Vision 本地识别文字 → LiveChatParser
// 按「气泡横向位置」分出我方/对方 → 快照写 App Group → 键盘与主 App 轮询读取，
// 把「对方最新一条 + 前文」交给现有 JevPipeline。整条链路里没有新依赖，
// 生成层、话术、判断层全部复用旧管线——输入从「剪贴板」换成了「屏幕」。

/// 一行识别出来的对话。side 靠气泡的横向位置判断（右半屏 = 我方），
/// 这是启发式：微信/QQ/iMessage 等主流 App 都满足，但换行气泡、贴图、引用块会识别错。
struct LiveLine: Codable, Equatable {
    enum Side: String, Codable {
        case them, me, system
    }

    var side: Side
    var text: String
}

/// 一次识别的完整快照。存 App Group UserDefaults，跨进程共享：
/// 广播扩展写，键盘与主 App 读。
/// 两个时间戳各司其职：`updatedAt` 是**心跳**（扩展每 2 秒落盘一次，广播活着它就新），
/// `changedAt` 才是**画面内容最后一次变化**（主 App 用它做防抖，对方连发时不急着分析）。
/// 早期版本只有「内容变了才落盘」一个语义，结果广播刚启动、OCR 冷启动还没出活的窗口里
/// App 永远显示「未在监听」（2026-09-24 真机第一次实测就是死在这上头）。
struct LiveSnapshot: Codable, Equatable {
    var updatedAt: Date
    var changedAt: Date
    var lines: [LiveLine]
    /// 扩展自启动以来见过的帧数（诊断用，够判断「广播活着但没有新帧」）
    var frameCount: Int
    /// 最近识别过的**全部对方消息**（新→旧，去重，跨帧累积）。v3 加入。
    /// 键盘弹出时聊天 App 会自动滚到最底，当前帧里往往只剩最新的几条——用户想回
    /// 更早的消息就得靠这份累积（2026-10-22 用户实测需求「我想同时能回复历史的消息」）。
    var recent: [String] = []

    /// 当前该回的消息：跳过尾部的系统行（时间/撤回提示），从尾往前取连续的对方气泡。
    /// 多行气泡合并成一条；没有对方消息（比如最后一屏全是自己发的）返回 nil。
    var latestIncoming: String? {
        var i = lines.count - 1
        while i >= 0, lines[i].side == .system { i -= 1 }
        guard i >= 0, lines[i].side == .them else { return nil }
        var buf: [String] = []
        while i >= 0, lines[i].side == .them {
            buf.insert(lines[i].text, at: 0)
            i -= 1
        }
        let joined = buf.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// 前文（给管线的 context）：latestIncoming 之前的对话，带说话人前缀，
    /// 只取最近 14 行 / 600 字——上下文是给起草模型定语气的，太长白花 token。
    var contextText: String? {
        var i = lines.count - 1
        while i >= 0, lines[i].side == .system { i -= 1 }
        guard i >= 0, lines[i].side == .them else { return nil }
        var buf: [String] = []
        var j = i - 1
        while j >= 0, buf.count < 14 {
            let line = lines[j]
            switch line.side {
            case .them: buf.insert("对方：" + line.text, at: 0)
            case .me: buf.insert("我：" + line.text, at: 0)
            case .system: break
            }
            j -= 1
        }
        let joined = buf.joined(separator: "\n").suffix(600)
        return joined.isEmpty ? nil : String(joined)
    }
}

// MARK: - 对话解析（纯函数，App 的自检页可以直接喂截图验证）

enum LiveChatParser {

    /// Vision 的输出：文本 + 归一化包围盒（原点左下）。抽成值类型方便测试与自检页复用。
    struct Observation {
        var text: String
        var boundingBox: CGRect
    }

    /// 聊天界面的固定 UI 文案，识别出来也没信息量。含两组：
    /// ① 聊天 App 自己的底部/状态词；② 我们自家 App/键盘的界面词——广播打开时屏幕上
    /// 常有自家 UI（回「直播」页看结果、键盘面板盖住下半屏），不洗掉它们就会混进快照、
    /// 甚至被当成「对方消息」触发分析（2026-10-22 真机快照实锤：OCR 认出了「AI 分析输入框文字」）。
    /// 精确整行匹配，聊天正文撞上这些词的概率可忽略。
    private static let uiTokens: Set<String> = [
        "发送", "输入", "按住说话", "按住 说话", "语音", "相册", "红包", "转账",
        "返回", "微信", "正在输入", "对方正在输入...", "已读", "已送达", "哇", "拍一拍",
        "开始", "模型", "话术", "直播", "试一试", "状态", "配置", "建议", "自检",
        "秒回", "Jev", "Jev Jarvis", "已连接", "监听中", "未在监听", "屏幕监听", "识别结果",
        "允许完全访问", "键盘已启用", "App Group 共享", "三步启用", "分析剪贴板",
        "AI 分析输入框文字", "读屏幕分析", "换一批", "重试", "好了",
    ]
    /// 时间行：`20:31`、`昨天 21:05`、`星期二`，以及 iOS 聊天 App 的跨天分隔行
    /// `9月26日 23:00` / `10月15日15:23`——后者不洗掉会被并进「对方消息」，
    /// 待回内容里混进日期（2026-10-22 真机快照实锤）。
    private static let timePattern = try! NSRegularExpression(pattern:
        #"^([0-9]{1,2}[:：][0-9]{2}|(昨天|今天)\s*[0-9]{1,2}[:：][0-9]{2}|[0-9]{1,2}月[0-9]{1,2}日(\s*[0-9]{1,2}[:：][0-9]{2})?|星期[一二三四五六日天]|昨天|今天)$"#)

    /// 观测 → 对话行。步骤：清洗 → 按 midY 聚成视觉行 → 行内按 x 拼接 → 并集框中点定左右。
    static func parse(_ observations: [Observation]) -> [LiveLine] {
        let cleaned: [Observation] = observations.compactMap { o in
            let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if uiTokens.contains(t) { return nil }
            if timePattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return nil }
            return Observation(text: t, boundingBox: o.boundingBox)
        }
        guard !cleaned.isEmpty else { return [] }

        // Vision 的 y 轴向上（原点左下）：从上往下扫，midY 接近的算同一视觉行。
        // 0.55 × 行高是经验值：同一行内多框（中文一段常碎成几框）的 midY 几乎重合，
        // 相邻两行气泡的高度差远大于半个行高。
        let sorted = cleaned.sorted { a, b in
            let am = a.boundingBox.midY, bm = b.boundingBox.midY
            return am == bm ? a.boundingBox.midX < b.boundingBox.midX : am > bm
        }
        var rows: [[Observation]] = []
        for o in sorted {
            if var last = rows.last, let first = last.first {
                let tol = 0.55 * max(first.boundingBox.height, o.boundingBox.height, 0.02)
                if abs(first.boundingBox.midY - o.boundingBox.midY) < tol {
                    last.append(o)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append([o])
        }

        var lines: [LiveLine] = []
        for row in rows {
            let items = row.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
            var text = ""
            for item in items {
                if let last = text.last, joinsTight(last, item.text.first ?? " ") {
                    text += item.text
                } else {
                    if !text.isEmpty { text += " " }
                    text += item.text
                }
            }
            // 并集框中点：短气泡贴边（微信里「哦」在对方手里 midX≈0.15，在我方手里 midX≈0.9），
            // 长气泡趋中。0.55 偏向我方一点，因为长消息里我方气泡整体更靠右。
            let union = items.dropFirst().reduce(items[0].boundingBox) { $0.union($1.boundingBox) }
            let side: LiveLine.Side = union.midX > 0.55 ? .me : .them
            lines.append(LiveLine(side: side, text: text))
        }
        return lines
    }

    /// 行内多框拼接：两边都是 CJK 就贴死（OCR 常把一句中文切成几框，加空格反而碍事），
    /// 否则补空格保住英文词距。
    private static func joinsTight(_ left: Character, _ right: Character) -> Bool {
        func cjk(_ c: Character) -> Bool {
            guard let s = String(c).unicodeScalars.first else { return false }
            return (0x4E00...0x9FFF).contains(s.value) || (0x3000...0x303F).contains(s.value)
                || (0xFF00...0xFFEF).contains(s.value)
        }
        return cjk(left) && cjk(right)
    }

    /// 一帧里的全部对方消息簇（新→旧）。与 latestIncoming 同规则（多行合并、系统行当边界），
    /// 但不只在帧尾找——用户滚动浏览聊天历史时，扩展每帧都能看到不同片段，
    /// 逐帧把这里的结果去重累积进快照 recent，键盘才能让用户挑「更早的消息」来回复。
    static func incomingClusters(in lines: [LiveLine]) -> [String] {
        var clusters: [String] = []
        var i = lines.count - 1
        while i >= 0 {
            guard lines[i].side == .them else { i -= 1; continue }
            var buf: [String] = []
            while i >= 0, lines[i].side == .them {
                buf.insert(lines[i].text, at: 0)
                i -= 1
            }
            let joined = buf.joined(separator: "\n")
            if !joined.isEmpty { clusters.append(joined) }
        }
        return Array(clusters.prefix(4))
    }

    /// 会话画面门控：广播扩展拿不到「当前前台 App」（iOS 不提供该 API，按 App 白名单
    /// 过滤做不到，见 docs/LIVE_MODE.md 第五节），退而求其次——只把「长得像双人聊天」
    /// 的画面当会话：我方与对方两侧气泡同时在场。真实聊天几乎总满足（有来才有回）；
    /// 设置/相册/网页等单列画面几乎不会同时出现左右两种气泡。2026-10-22 用户提出
    /// 「不是在聊天 App 里也一直 OCR」后的隐私收口。
    static func looksLikeConversation(_ lines: [LiveLine]) -> Bool {
        var them = 0, me = 0
        for line in lines {
            if line.side == .them { them += 1 }
            else if line.side == .me { me += 1 }
        }
        return them >= 1 && me >= 1
    }

    /// 会话延续判定：本帧与上一帧有共同文本行。用户在聊天里滚动浏览时（包括翻到
    /// 只剩单侧气泡的老历史，2026-10-22 用户反馈「滑到最上面一点输入框就弹回最底」），
    /// 相邻两帧的画面必有交集；切到别的 App 则内容完全不同、交集为空。
    /// 与 looksLikeConversation 二选一满足即视为会话——否则门控会把单侧气泡的
    /// 历史区间整段漏掉，「回复更早」就累积不到用户翻过的消息。
    static func extendsConversation(_ current: [LiveLine], previous: [LiveLine]) -> Bool {
        guard !previous.isEmpty else { return false }
        let cur = Set(current.map(\.text))
        let prev = Set(previous.map(\.text))
        return !cur.isDisjoint(with: prev)
    }

    // MARK: 同一句话识别变体的归并（模糊去重）

    /// OCR 抖动归一化：去空白、小写。同一句话两帧识别常在空格/断行位置上不一致
    ///（「拉一\n把」vs「拉一 把」vs「拉一把」），归一化后才能对上。
    static func normalizedForDedup(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 两条识别结果是否指同一句话：归一化后相等，或一方包含另一方且较短方 ≥6 字
    /// （滚动中只露半条的截断变体），或归一化后编辑距离占比较小（逐字抖动：
    /// 「wizard」偶发认成「wizzard」，包含关系判不出来）。短消息（<8 字）不用距离——
    /// 「好的」和「好的呀」是真不同的消息，防止误吞。
    static func areSameMessage(_ a: String, _ b: String) -> Bool {
        let na = normalizedForDedup(a)
        let nb = normalizedForDedup(b)
        if na == nb { return true }
        let (short, long) = na.count < nb.count ? (na, nb) : (nb, na)
        if short.count >= 6 && long.contains(short) { return true }
        guard short.count >= 8, na.count <= 400, nb.count <= 400 else { return false }
        return levenshtein(na, nb) <= max(2, Int(0.15 * Double(max(na.count, nb.count))))
    }

    /// 经典 DP 编辑距离。消息都是短文本（≤ 数百字），每 2 秒至多 24 次比较，开销可忽略。
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}

// MARK: - App Group 存储

/// 快照的唯一存放点。不放新文件进容器目录——UserDefaults 跨进程同步由 cfprefsd 负责，
/// 键盘 2 秒轮询一次小 key 的开销可以忽略。
enum JevLiveStore {
    /// v3：加了 recent（跨帧累积的对方消息历史，支撑「回复更早的消息」）。
    /// v2 加过 changedAt；v1 从来没有成功写出来过（见 LiveSnapshot 注释），无需迁移。
    static let snapshotKey = "jev.live.snapshot.v3"
    /// 与 JevStore.appGroupID 同值。JevLive.swift 单文件编译进广播扩展（不带 JevModel），
    /// 所以这里自带一份——改 App Group 时 entitlements / project.yml / 这两处要一起改。
    private static let appGroupID = "group.81c139ae9a27a7f8.1"
    /// 快照多久之内算「监听中」。扩展靠 2 秒一次的心跳维持 updatedAt，
    /// 广播一停快照自然过期，键盘/主 App 据此回到空闲，不需要显式的停止信号。
    static let freshWindow: TimeInterval = 150

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func save(_ snapshot: LiveSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> LiveSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(LiveSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// 把本帧识别到的对方消息簇并进累积历史：新的在前、模糊去重（areSameMessage，
    /// 同一句话的识别变体只留一条、以更全的版本为准）、封顶。
    /// found 与 existing 都是新→旧序。封顶 6 条——键盘上最多展示 3 条（主目标+2 个更早），
    /// 留一倍冗余；再多用户也挑不过来，还平白增大快照体积。
    static func mergingRecent(existing: [String], found: [String], cap: Int = 6) -> [String] {
        var out: [String] = []
        for msg in found + existing {
            if let i = out.firstIndex(where: { LiveChatParser.areSameMessage($0, msg) }) {
                if msg.count > out[i].count { out[i] = msg }   // 识别更全的版本顶掉残缺版
            } else {
                out.append(msg)
            }
        }
        return Array(out.prefix(cap))
    }

    static func isFresh(_ snapshot: LiveSnapshot) -> Bool {
        Date().timeIntervalSince(snapshot.updatedAt) < freshWindow
    }

    /// 「监听中且能 actionable」= 快照新鲜 + 里面有一条待回的对方消息。
    /// 键盘待机页用这一个布尔决定要不要显示「读屏幕分析」按钮。
    static var isActionable: Bool {
        guard let snap = load(), isFresh(snap), snap.latestIncoming != nil else { return false }
        return true
    }

    /// 「广播活着」= 快照新鲜（扩展每 2 秒心跳落盘）。比 isActionable 宽：
    /// 广播刚开、还没读到对方气泡时也是 true。键盘待机页用它显示「监听中」提示——
    /// 2026-10-22 真机首试的教训：按钮要等识别到对方消息才出现，而用户在那之前的
    /// 两分钟里完全看不出键盘有任何直播相关的反应，以为功能没生效。
    static var isListening: Bool {
        guard let snap = load() else { return false }
        return isFresh(snap)
    }

    // MARK: 自报状态（键盘 / 主 App 写，广播扩展读）

    /// 键盘面板高度占整屏的比例。键盘开着时它自己周期性上报（带时间戳），
    /// 广播扩展据此抬高底部裁剪——键盘面板在识别区里会被 OCR，按钮上显示的
    /// 上一轮目标还会被喂回快照形成自反馈，recent 全变成按钮文本的变体
    ///（2026-10-22 日志实锤）。
    struct PanelState: Codable {
        var fraction: Double
        var at: Date
    }

    private static let keyboardPanelKey = "jev.live.keyboardPanel.v1"
    private static let appLiveVisibleKey = "jev.live.appVisible.v1"

    static func setKeyboardPanel(fraction: Double) {
        guard let data = try? JSONEncoder().encode(PanelState(fraction: fraction, at: Date())) else { return }
        defaults.set(data, forKey: keyboardPanelKey)
    }

    /// 过期（键盘没在跑/进程死了没来得及清）返回 0 = 不抬底部裁剪。
    static func keyboardPanelFraction(maxAge: TimeInterval = 20) -> Double {
        guard let data = defaults.data(forKey: keyboardPanelKey),
              let state = try? JSONDecoder().decode(PanelState.self, from: data),
              Date().timeIntervalSince(state.at) < maxAge else { return 0 }
        return state.fraction
    }

    /// App「直播」页在前台时自报（每秒续期）。页面上是我们自己的识别结果 UI，OCR 它
    /// 只会把上一轮目标喂回快照（同一个自反馈回路），扩展看到新鲜标记直接整帧跳过。
    /// 用时间戳而不是裸布尔：用户带着直播页退后台时 onDisappear 不可靠，
    /// 卡死的 true 会让扩展在用户回到聊天后仍然永远跳过。
    static func setAppLiveVisible(_ visible: Bool) {
        guard let data = try? JSONEncoder().encode(PanelState(fraction: visible ? 1 : 0, at: Date())) else { return }
        defaults.set(data, forKey: appLiveVisibleKey)
    }

    static func appLiveVisible(maxAge: TimeInterval = 5) -> Bool {
        guard let data = defaults.data(forKey: appLiveVisibleKey),
              let state = try? JSONDecoder().decode(PanelState.self, from: data),
              state.fraction > 0,
              Date().timeIntervalSince(state.at) < maxAge else { return false }
        return true
    }

    /// 扩展侧自检日志。广播扩展连 Xcode 控制台都看不着，出问题全靠这一条通道
    /// （与 JevStore.diag 共用同一个 key：App/键盘/扩展三个进程谁写的都能读到）。
    /// 不做 DEBUG 门控：LiveBroadcastHandler 无条件调用它，而 Release/Archive 配置下
    /// DEBUG 编译条件不存在，门控会让 0.2.0 起的重提 Archive 直接编译失败；
    /// 每次只写几百字节，Release 留着它正好排查真机 50MB 内存问题。
    static func diag(_ line: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let prev = defaults.string(forKey: "jev.diag.v1") ?? ""
        defaults.set(String((prev + "[\(stamp)] [直播] \(line)\n").suffix(6000)),
                     forKey: "jev.diag.v1")
    }
}

// MARK: - OCR 引擎（广播扩展与自检页共用的同一条识别路径）

enum LiveOCREngine {

    /// 只识别聊天区：裁掉顶部状态栏+导航栏 (~12%)；底部裁剪默认 14%（输入条），
    /// 键盘开着时由广播扩展按自报的面板高度抬高（见 setKeyboardPanel）。
    /// 顶部 5% 不够——群聊名称显示在导航栏里（约在顶部 9-11% 处），居中显示会被判成
    /// 「对方」混进待回目标（2026-10-22 用户实测：按钮读出了群名「732-…」），
    /// 提到 12% 把状态栏+导航栏整条排除。
    /// 注意：设了 regionOfInterest 后，结果的 boundingBox 是相对该区域的归一化坐标——
    /// 我们只用 midX 定左右、midY 排序，两种坐标系下结论一致。
    static func regionOfInterest(bottomCut: CGFloat = 0.14) -> CGRect {
        CGRect(x: 0, y: bottomCut, width: 1, height: max(0.2, 0.88 - bottomCut))
    }

    static func recognize(pixelBuffer: CVPixelBuffer, bottomCut: CGFloat = 0.14) -> [LiveLine] {
        var lines: [LiveLine] = []
        // 广播扩展内存上限 ~50MB（jetsam 硬杀）：识别全程包在 autoreleasepool 里，
        // 帧用完即还；识别档位与耗时见 makeRequest() 里的说明。
        autoreleasepool {
            // 全屏帧（1170×2532 的 NV12 ≈ 11.9MB，Vision 内部中间缓冲还要翻几倍）
            // 直接喂 accurate 档有顶爆 50MB 的风险——先缩到 720 宽灰度图（≈1.1MB）再识别
            let buffer = downscaledGray(pixelBuffer) ?? pixelBuffer
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
            let request = makeRequest(bottomCut: bottomCut)
            try? handler.perform([request])
            lines = finish(request)
        }
        return lines
    }

    /// 自检页用：静态图（截图/合成示例）走同一条解析路径。
    static func recognize(cgImage: CGImage) -> [LiveLine] {
        var lines: [LiveLine] = []
        autoreleasepool {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            let request = makeRequest()
            try? handler.perform([request])
            lines = finish(request)
        }
        return lines
    }

    private static func makeRequest(bottomCut: CGFloat = 0.14) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // 档位必须是 accurate：冒烟实测（macOS 同源 Vision）fast 档对中文几乎全瞎
        //（5 条气泡只认出 1 个英文词），accurate 档全对。代价是单帧更慢更吃内存，
        // 靠 2 秒节流摊平；万一真机上 50MB 上限杀进程，把这里改回 .fast 再议。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.015
        request.regionOfInterest = regionOfInterest(bottomCut: bottomCut)
        return request
    }

    private static func finish(_ request: VNRecognizeTextRequest) -> [LiveLine] {
        let observations = (request.results ?? []).compactMap { o -> LiveChatParser.Observation? in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            return LiveChatParser.Observation(text: text, boundingBox: o.boundingBox)
        }
        return LiveChatParser.parse(observations)
    }

    /// 缩到 ≤720 宽的单通道灰度 buffer。ReplayKit 的帧是 NV12，plane0 本身就是亮度图，
    /// 直接用 vImage 缩放——不用 CIContext（那玩意自己就吃掉几十 MB），不经 RGB 转换。
    /// 非 NV12 返回 nil，调用方退回原 buffer：宁可多花内存，不牺牲正确性。
    private static func downscaledGray(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(src)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(src) > 0 else { return nil }

        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let targetW = 720
        guard srcW > targetW else { return nil }
        var dst: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, targetW, Int(Double(srcH) / Double(srcW) * Double(targetW)),
            kCVPixelFormatType_OneComponent8, nil, &dst)
        guard createStatus == kCVReturnSuccess, let gray = dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        var srcBuf = vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(src, 0),
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(src, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(src, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, 0))
        CVPixelBufferLockBaseAddress(gray, [])
        defer { CVPixelBufferUnlockBaseAddress(gray, []) }
        var dstBuf = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(gray),
            height: vImagePixelCount(CVPixelBufferGetHeight(gray)),
            width: vImagePixelCount(CVPixelBufferGetWidth(gray)),
            rowBytes: CVPixelBufferGetBytesPerRow(gray))
        let err = vImageScale_Planar8(&srcBuf, &dstBuf, nil,
                                      vImage_Flags(kvImageHighQualityResampling))
        return err == kvImageNoError ? gray : nil
    }
}
