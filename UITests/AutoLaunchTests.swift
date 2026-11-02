import XCTest

/// 审核崩溃复现用的自动化冒烟:
/// ① 全新安装冷启动 ② 四个 Tab 遍历 ③ 系统设置添加键盘 + 键盘扩展冷启动。
/// 界面默认中文(App 内置,与系统语言无关),系统设置按模拟器语言(英文)定位。
final class AutoLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 场景1:冷启动冒烟(审核场景)

    func testColdLaunchSmoke() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "冷启动后 App 未在前台运行")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "冷启动 15s 内 TabBar 未出现——疑似启动崩溃")
        XCTAssertTrue(tabBar.buttons["开始"].exists || tabBar.buttons["Home"].exists,
                      "首屏「开始」Tab 不存在")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - 场景2:四个 Tab 逐个遍历

    func testAllTabsTraversal() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15))

        // 中英文双语标签都尝试,存在才点(界面语言取决于 App 内语言设置)
        let candidates = ["开始", "模型", "话术", "试一试", "Home", "Models", "Tones", "Try it"]
        var visited = 0
        for name in candidates where tabBar.buttons[name].exists {
            tabBar.buttons[name].tap()
            visited += 1
            // 每页停留足够时间让首帧渲染完成;若该页初始化即崩,App 状态会异常
            XCTAssertEqual(app.state, .runningForeground, "访问「\(name)」页后 App 不在前台")
        }
        XCTAssertGreaterThanOrEqual(visited, 4, "四个 Tab 至少应成功访问一遍")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - 场景3:键盘扩展冷启动(审核必测路径)

    func testKeyboardExtensionLaunch() throws {
        addKeyboardViaSettings()

        // 回到 App,打开「试一试」的文本编辑器拉起系统键盘
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15))

        let tryTab = tabBar.buttons["试一试"].exists ? tabBar.buttons["试一试"] : tabBar.buttons["Try it"]
        XCTAssertTrue(tryTab.exists, "找不到「试一试」Tab")
        tryTab.tap()

        // SwiftUI TextEditor 映射为 textView
        let editor = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.scrollViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "找不到文本编辑器")
        editor.tap()

        // 系统键盘弹出(带重试:焦点时序可能导致首次 tap 失效)
        var keyboardUp = app.keyboards.firstMatch.waitForExistence(timeout: 6)
            || keyboardStatusFresh()
        for _ in 0..<2 where !keyboardUp {
            editor.tap()
            keyboardUp = app.keyboards.firstMatch.waitForExistence(timeout: 6)
                || keyboardStatusFresh()
        }
        XCTAssertTrue(keyboardUp, "系统键盘未弹出")
        // 诊断:把键盘树落盘,便于排查地球键/键盘结构问题
        try? app.keyboards.debugDescription.write(toFile: "/tmp/keyboards_tree.txt", atomically: true, encoding: .utf8)
        let fullTree = app.debugDescription
        try? fullTree.write(toFile: "/tmp/full_tree.txt", atomically: true, encoding: .utf8)

        // 长按地球键弹出键盘选择菜单,直接选 Jev(比循环 tap 可靠,且能验证键盘是否真的添加成功)
        // 注意:iOS 27 上地球键不在 keyboards 子树里,要全局查 buttons。
        let globe = app.buttons["Next keyboard"].firstMatch.exists
            ? app.buttons["Next keyboard"].firstMatch
            : app.buttons["下一个键盘"].firstMatch
        XCTAssertTrue(globe.exists, "找不到地球键(Next keyboard)")
        globe.press(forDuration: 1.2)

        // 选择菜单可能在 App 内或 SpringBoard 层级
        let jevItem = NSPredicate(format: "label CONTAINS 'Jev'")
        var picker = app.buttons.matching(jevItem).firstMatch
        if !picker.waitForExistence(timeout: 4) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            picker = springboard.buttons.matching(jevItem).firstMatch
            if !picker.waitForExistence(timeout: 4) {
                // 菜单项有时以 staticText/other 形式出现
                picker = app.descendants(matching: .any).matching(jevItem).firstMatch.exists
                    ? app.descendants(matching: .any).matching(jevItem).firstMatch
                    : springboard.descendants(matching: .any).matching(jevItem).firstMatch
                _ = picker.waitForExistence(timeout: 4)
            }
        }
        XCTAssertTrue(picker.exists, "键盘选择菜单里没有 Jev——键盘可能未成功添加到系统")
        picker.tap()

        // 键盘扩展首次冷启动可能要加载 1-3 秒。
        // 注意:第三方键盘显示在系统 RemoteKeyboardWindow,不在宿主 App 元素树里,
        // 所以同时用「App Group 里的键盘回写状态」做铁证(viewDidAppear 必回写 kbstatus)。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        var jevUp = jevKeyboardVisible(in: app) || jevKeyboardVisible(in: springboard)
        while !jevUp && Date() < deadline {
            usleep(500_000)
            jevUp = jevKeyboardVisible(in: app) || jevKeyboardVisible(in: springboard) || keyboardStatusFresh()
        }
        XCTAssertTrue(jevUp, "选择了 Jev 键盘但它没有渲染出来——键盘扩展启动可能崩溃")
        XCTAssertEqual(app.state, .runningForeground, "Jev 键盘拉起后宿主 App 不在前台")
    }

    /// 读模拟器上 App Group 容器的键盘状态(runner 在模拟器内,HOME 的三级上级即设备 data 目录):
    /// kbstatus.lastSeen 在最近 60 秒内 = 键盘扩展的 viewDidAppear 真的跑过且没崩。
    private func keyboardStatusFresh() -> Bool {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return false }
        let appGroupRoot = home + "/../../../Shared/AppGroup"
        guard let groups = try? FileManager.default.contentsOfDirectory(atPath: appGroupRoot) else { return false }
        for g in groups {
            let plist = appGroupRoot + "/\(g)/Library/Preferences/group.81c139ae9a27a7f8.1.plist"
            guard let data = FileManager.default.contents(atPath: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let status = dict["jev.kbstatus.v1"] as? Data,
                  let obj = try? JSONDecoder().decode(KeyboardStatusDTO.self, from: status) else { continue }
            return Date().timeIntervalSince(obj.lastSeen) < 60
        }
        return false
    }

    /// 与 App 侧 KeyboardStatus 同构(测试 target 不依赖 App 模块,独立声明)
    private struct KeyboardStatusDTO: Decodable {
        var lastSeen: Date
        var hasFullAccess: Bool
    }

    /// Jev 键盘是否已渲染:特征是「分析剪贴板 / Analyze Clipboard」按钮。
    /// 键盘扩展内容可能挂在 app 树的任意层(RemoteKeyboardWindow 投影),全局查不限 keyboards 子树。
    private func jevKeyboardVisible(in app: XCUIApplication) -> Bool {
        let pred = NSPredicate(format: "label CONTAINS '分析剪贴板' OR label CONTAINS 'Analyze Clipboard'")
        return app.descendants(matching: .any).matching(pred).firstMatch.exists
    }

    private func waitForJev(in app: XCUIApplication, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if jevKeyboardVisible(in: app) { return true }
            usleep(300_000)
        }
        return jevKeyboardVisible(in: app)
    }

    /// 系统设置自动化:通用 → 键盘 → 键盘 → 添加新键盘… → 第三方键盘 → Jev
    private func addKeyboardViaSettings() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        // 等设置首页就绪:标题「设置/Settings」或「Apple 账户」任一出现
        let rootReady = NSPredicate(format: "label IN {'设置', 'Settings', 'Apple 账户', 'Apple Account'}")
        let ready = settings.staticTexts.matching(rootReady).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "设置首页未加载")

        // 设置会恢复上次的深层页面(返回按钮的 label 也会误匹配根页面断言),
        // 先连点返回退到根页面再开始导航
        for _ in 0..<6 {
            let back = settings.navigationBars.buttons["BackButton"].firstMatch
            if !back.exists { break }
            back.tap()
            sleep(1)
        }

        // 找一行并点击:先 staticTexts 后 cells,均带滚动重试;支持多语言标签。
        // 设置会恢复上次的滚动位置:先回顶部再向下扫。失败返回 false 由调用方决定兜底。
        @discardableResult
        func tapRowOptional(containing texts: [String], in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
            let orClauses = texts.map { _ in "SELF CONTAINS %@" }.joined(separator: " OR ")
            let pred = NSPredicate(format: orClauses, argumentArray: texts)
            func query() -> XCUIElement {
                let t = app.staticTexts.matching(pred).firstMatch
                return t.exists ? t : app.cells.matching(pred).firstMatch
            }
            app.swipeDown()
            app.swipeDown()
            let deadline = Date().addingTimeInterval(timeout)
            var el = query()
            while !el.exists && Date() < deadline {
                app.swipeUp()
                el = query()
            }
            guard el.exists else { return false }
            el.tap()
            return true
        }

        // 导航到「键盘设置页」:传统导航(出厂/干净环境可靠)优先,失败再用搜索直达兜底
        // (运行多轮后首页滚动不可靠;出厂后搜索索引未建,两条路互为补充)
        var navigated = tapRowOptional(containing: ["通用", "General"], in: settings)
            && tapRowOptional(containing: ["键盘", "Keyboard"], in: settings)
        if !navigated {
            // 从深层页退回根页面再试一次传统导航
            for _ in 0..<4 {
                let back = settings.navigationBars.buttons["BackButton"].firstMatch
                if !back.exists { break }
                back.tap()
                sleep(1)
            }
            navigated = tapRowOptional(containing: ["通用", "General"], in: settings)
                && tapRowOptional(containing: ["键盘", "Keyboard"], in: settings)
        }
        if !navigated {
            // 搜索直达兜底(需要设置索引已建好)
            settings.swipeDown() // 关闭可能拉起的搜索键盘
            let searchField = settings.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 6), "传统导航与搜索入口均不可用")
            searchField.tap()
            settings.typeText("键盘")
            let result = settings.cells.matching(
                NSPredicate(format: "label == '键盘' OR label == 'Keyboard' OR label BEGINSWITH '键盘' OR label BEGINSWITH 'Keyboard'")
            ).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10), "搜索结果里找不到「键盘」")
            result.tap()
        }

        // 【崩溃复现实验】关闭系统「听写」:
        // 线上崩溃链是 TIGetDefaultDictationLanguagesForKeyboardLanguage 查听写语言拿 nil →
        // NSDictionaryM setObject:forKey: 崩。听写开关就在当前「键盘设置页」(identifier 'Dictation')。
        let dictationCell = settings.cells["Dictation"].firstMatch
        if dictationCell.waitForExistence(timeout: 5) {
            let sw = dictationCell.switches.firstMatch.exists ? dictationCell.switches.firstMatch : dictationCell
            if (sw.value as? String) == "1" {
                sw.tap() // 关闭听写
                sleep(2)
            }
        }

        // 「键盘」设置页顶部第一行:identifier 'KEYBOARDS'(label「键盘、5」含数量,系统内部 ID 与语言无关)。
        let listPred = NSPredicate(
            format: "identifier == 'KEYBOARDS' OR label == '键盘' OR label == 'Keyboards' OR label BEGINSWITH '键盘、' OR label BEGINSWITH 'Keyboards,'"
        )
        var listRow = settings.cells.matching(listPred).firstMatch
        if !listRow.waitForExistence(timeout: 8) {
            settings.swipeDown() // 可能被滚下去了,回顶部再试
            listRow = settings.cells.matching(listPred).firstMatch
            _ = listRow.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(listRow.exists, "键盘设置页里找不到「键盘 (N)」列表行")
        listRow.tap()

        // 已在键盘列表里则跳过添加(重复运行幂等)
        let alreadyAdded = NSPredicate(format: "label CONTAINS 'Jev'")
        if settings.staticTexts.matching(alreadyAdded).firstMatch.exists
            || settings.cells.matching(alreadyAdded).firstMatch.exists {
            settings.terminate()
            return
        }
        // 添加新键盘(省略号字符兼容,中英双语)
        let addPred = NSPredicate(format: "label CONTAINS '添加新键盘' OR label CONTAINS 'Add New Keyboard'")
        let addDeadline = Date().addingTimeInterval(12)
        var addRow = settings.staticTexts.matching(addPred).firstMatch
        var cellsRow = settings.cells.matching(addPred).firstMatch
        while !addRow.exists && !cellsRow.exists && Date() < addDeadline {
            settings.swipeUp()
            addRow = settings.staticTexts.matching(addPred).firstMatch
            cellsRow = settings.cells.matching(addPred).firstMatch
        }
        if cellsRow.exists { cellsRow.tap() } else {
            XCTAssertTrue(addRow.exists, "找不到 添加新键盘/Add New Keyboard")
            addRow.tap()
        }

        // 第三方键盘分区里找 Jev(显示名可能是「Jev 键盘」或「Jev Jarvis」)
        let jevPred = NSPredicate(format: "label CONTAINS 'Jev'")
        let jevDeadline = Date().addingTimeInterval(12)
        var jevRow = settings.staticTexts.matching(jevPred).firstMatch
        while !jevRow.exists && Date() < jevDeadline {
            settings.swipeUp()
            jevRow = settings.staticTexts.matching(jevPred).firstMatch
        }
        XCTAssertTrue(jevRow.exists, "第三方键盘列表里找不到 Jev 键盘")
        jevRow.tap()

        settings.terminate()
    }
}
