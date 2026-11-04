//
//  KakaoBannerHider
//
//  카카오톡(맥) 창 하단의 광고 배너 자리를, 카카오톡 앱은 건드리지 않고
//  화면 위에 같은 색 판을 덮어 가리는 메뉴 막대 앱.
//
//  - 카카오톡 앱 파일/서명/설정/대화 내용을 수정하지 않는다.
//  - 광고 영역을 읽기 전용(Accessibility)으로 재서 그 위에 창을 하나 띄운다.
//  - 앱을 종료하면 덮개가 사라지고 원래 화면으로 즉시 돌아온다.
//

import AppKit
import ApplicationServices
import ServiceManagement

private let kakaoBundleID = "com.kakao.KakaoTalkMac"
private let defaults = UserDefaults.standard

// MARK: - Accessibility helpers

private func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
}

private func axString(_ el: AXUIElement, _ attr: String) -> String? {
    axValue(el, attr) as? String
}

private func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axValue(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

private func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axValue(el, kAXPositionAttribute as String),
          let s = axValue(el, kAXSizeAttribute as String),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var pt = CGPoint.zero
    var sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt),
          AXValueGetValue(s as! AXValue, .cgSize, &sz)
    else { return nil }
    return CGRect(origin: pt, size: sz)
}

private func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
    axValue(el, attr) as? Bool
}

/// AX 좌표(화면 왼쪽 위 원점) → Cocoa 좌표(화면 왼쪽 아래 원점)
private func cocoaRect(fromAX r: CGRect) -> NSRect {
    let mainH = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)
}

// MARK: - Private APIs (window id / window image)

private typealias GetWindowIDFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private typealias CaptureFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

private let getWindowIDFn: GetWindowIDFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: GetWindowIDFn.self)
}()

private let captureFn: CaptureFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CaptureFn.self)
}()

private func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let fn = getWindowIDFn else { return nil }
    var wid: CGWindowID = 0
    guard fn(element, &wid) == .success, wid != 0 else { return nil }
    return wid
}

private func captureWindowImage(_ wid: CGWindowID) -> CGImage? {
    // 1 << 3 == kCGWindowListOptionIncludingWindow, 1 << 0 == kCGWindowImageBoundsIgnoreFraming
    guard let fn = captureFn, let unmanaged = fn(.null, 1 << 3, wid, 1 << 0) else { return nil }
    return unmanaged.takeRetainedValue()
}

/// 광고 자리(rect, 화면 좌표)가 실제로 가려지지 않고 보이는지.
/// 카카오톡 창이 다른 창 뒤에 있으면 덮개를 띄우지 않는다.
private func isRectExposed(_ rect: CGRect, windowID wid: CGWindowID) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
        if id == wid { return true }                       // 여기까지 왔으면 가리는 창이 없다
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        if layer != 0 || alpha < 0.05 { continue }          // 메뉴 막대·독·오버레이 등은 무시
        guard let d = w[kCGWindowBounds as String] as? [String: Any],
              let x = (d["X"] as? NSNumber)?.doubleValue,
              let y = (d["Y"] as? NSNumber)?.doubleValue,
              let rw = (d["Width"] as? NSNumber)?.doubleValue,
              let rh = (d["Height"] as? NSNumber)?.doubleValue else { continue }
        if CGRect(x: x, y: y, width: rw, height: rh).intersects(rect) { return false }
    }
    return false
}


// MARK: - 사용량(Codex / Claude) 모델

private struct UsageWindow: Decodable {
    let label: String
    let remaining: Double?
    let resetAt: Int?
    enum CodingKeys: String, CodingKey { case label, remaining, resetAt = "reset_at" }
}

private struct UsageProvider: Decodable {
    let id: String
    let label: String
    let ok: Bool
    let plan: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let error: String?
}

private struct UsagePayload: Decodable {
    let updatedAt: Int?
    let providers: [UsageProvider]?
    enum CodingKeys: String, CodingKey { case updatedAt = "updated_at", providers }
}

/// 배너 자리에 Codex / Claude 남은 한도를 두 줄로 그린다.
private final class UsageView: NSView {
    var payload: UsagePayload? { didSet { needsDisplay = true } }
    var loading = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    private let unitFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        let rows = payload?.providers?.prefix(2).map { $0 } ?? []
        if rows.isEmpty {
            drawCentered(loading ? "한도 정보를 불러오는 중…" : "한도 정보를 읽지 못했습니다")
            return
        }
        let rowHeight = bounds.height / CGFloat(rows.count)
        for (i, provider) in rows.enumerated() {
            draw(provider: provider, centerY: rowHeight * (CGFloat(i) + 0.5))
        }
    }

    private func drawCentered(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.black.withAlphaComponent(0.4)
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    private func draw(provider: UsageProvider, centerY: CGFloat) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor.black.withAlphaComponent(provider.ok ? 0.62 : 0.3)
        ]
        let name = NSAttributedString(string: provider.label, attributes: nameAttrs)
        name.draw(at: NSPoint(x: 16, y: centerY - name.size().height / 2))

        guard provider.ok, let primary = provider.primary, let remaining = primary.remaining else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7)
            ]
            let detail = NSAttributedString(string: provider.error ?? "정보 없음", attributes: attrs)
            let size = detail.size()
            detail.draw(at: NSPoint(x: bounds.width - 16 - size.width, y: centerY - size.height / 2))
            return
        }

        // 게이지
        let barX: CGFloat = 86, barW: CGFloat = 132, barH: CGFloat = 6
        let barRect = NSRect(x: barX, y: centerY - barH / 2, width: barW, height: barH)
        NSColor.black.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
        let fillW = max(barH, barW * CGFloat(min(100, max(0, remaining)) / 100))
        NSColor.black.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: centerY - barH / 2, width: fillW, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
        accent(for: remaining).setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: centerY - barH / 2, width: fillW, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()

        // 퍼센트
        let pctText = String(format: "%.0f%%", remaining)
        let pct = NSAttributedString(string: pctText, attributes: [
            .font: pctFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.78)
        ])
        let pctX: CGFloat = 228
        pct.draw(at: NSPoint(x: pctX, y: centerY - pct.size().height / 2))
        let unit = NSAttributedString(string: " 남음", attributes: [
            .font: unitFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.38)
        ])
        unit.draw(at: NSPoint(x: pctX + pct.size().width, y: centerY - unit.size().height / 2 + 1))

        // 오른쪽: 창 이름 + 리셋 시각 (+ 두 번째 창)
        var detail = "\(primary.label) \(resetText(primary.resetAt))"
        if let second = provider.secondary, let rest = second.remaining {
            detail += String(format: " · %@ %.0f%%", second.label, rest)
        }
        let detailString = NSAttributedString(string: detail, attributes: [
            .font: detailFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.42)
        ])
        let size = detailString.size()
        detailString.draw(at: NSPoint(x: bounds.width - 16 - size.width, y: centerY - size.height / 2))
    }

    private func accent(for remaining: Double) -> NSColor {
        if remaining <= 15 { return NSColor.systemRed.withAlphaComponent(0.75) }
        if remaining <= 35 { return NSColor.systemOrange.withAlphaComponent(0.8) }
        return NSColor.systemBlue.withAlphaComponent(0.72)
    }

    private func resetText(_ epoch: Int?) -> String {
        guard let epoch else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: date)
    }
}

// MARK: - Panel

private final class BandView: NSView {
    var fill: NSColor = .white { didSet { needsDisplay = true } }
    var bottomRadius: CGFloat = 20 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = min(bottomRadius, bounds.height / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.minX, y: bounds.minY + r))
        path.appendArc(withCenter: NSPoint(x: bounds.minX + r, y: bounds.minY + r),
                       radius: r, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: bounds.maxX - r, y: bounds.minY))
        path.appendArc(withCenter: NSPoint(x: bounds.maxX - r, y: bounds.minY + r),
                       radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        path.close()
        fill.setFill()
        path.fill()
    }
}

private final class BandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

private enum DisplayMode: String {
    case blank, clock, text, usage
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var panel: BandPanel!
    private var bandView: BandView!
    private var label: NSTextField!
    private var usageView: UsageView!

    private var tickTimer: Timer?
    private var clockTimer: Timer?

    private var enabled: Bool = defaults.object(forKey: "enabled") as? Bool ?? true
    private var mode: DisplayMode = DisplayMode(rawValue: defaults.string(forKey: "mode") ?? "usage") ?? .usage
    private var customText: String = defaults.string(forKey: "customText") ?? "여기는 내 자리"

    private var statusItemTitle = ""
    private var lastRect: NSRect = .zero
    private var bandHeightCache: CGFloat?
    private var cachedWindowSize: CGSize = .zero
    private var lastBandHeight: CGFloat = 0
    private var cachedColor: NSColor?
    private var lastColorSample = Date.distantPast
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f
    }()
    private var trusted = false
    private let forceShow = ProcessInfo.processInfo.environment["KBH_FORCE_SHOW"] == "1"
    private let debug = ProcessInfo.processInfo.environment["KBH_DEBUG"] == "1"

    private func log(_ s: String) {
        guard debug else { return }
        FileHandle.standardError.write(("[kbh] " + s + "\n").data(using: .utf8)!)
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildPanel()

        trusted = AXIsProcessTrusted()
        log("launch trusted=\(trusted) forceShow=\(forceShow)")
        if !trusted {
            // 권한 요청 창을 한 번 띄운다.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
        }

        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        let c = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshClock() }
        RunLoop.main.add(c, forMode: .common)
        clockTimer = c

        startUsageLoop()
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        clockTimer?.invalidate()
        panel?.orderOut(nil)
    }

    // MARK: ui

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = makeMenu()
    }

    private static func statusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 3.6, width: 15.6, height: 10.8),
                                   xRadius: 2.6, yRadius: 2.6)
            box.lineWidth = 1.2
            box.stroke()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 6.5, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            let text = NSAttributedString(string: "AD", attributes: attrs)
            let ts = text.size()
            text.draw(at: NSPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2 + 0.5))

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 2.4, y: 2.8))
            slash.line(to: NSPoint(x: 15.6, y: 15.2))
            slash.lineWidth = 1.6
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 100
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "광고 가리기", action: #selector(toggleEnabled), keyEquivalent: "d")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let modeItem = NSMenuItem(title: "가린 자리에 표시", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (m, title) in [(DisplayMode.usage, "Codex · Claude 남은 한도"),
                           (.blank, "아무것도 없이 (빈 공간)"),
                           (.clock, "시계"),
                           (.text, "내 문구")] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (mode == m) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let edit = NSMenuItem(title: "문구 바꾸기…", action: #selector(editText), keyEquivalent: "")
        edit.target = self
        sub.addItem(edit)
        modeItem.submenu = sub
        menu.addItem(modeItem)

        let refresh = NSMenuItem(title: "한도 지금 새로고침", action: #selector(refreshUsage), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let login = NSMenuItem(title: "로그인할 때 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let bring = NSMenuItem(title: "카카오톡 앞으로 가져오기", action: #selector(bringKakaoForward), keyEquivalent: "")
        bring.target = self
        menu.addItem(bring)

        if !trusted {
            let perm = NSMenuItem(title: "손쉬운 사용 권한 필요 — 설정 열기", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료 (광고 원래대로)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func statusTitle() -> String {
        guard enabled else { return "광고 가리기 꺼짐" }
        guard trusted else { return "손쉬운 사용 권한이 필요합니다" }
        guard kakaoApp() != nil else { return "카카오톡이 실행되면 자동으로 가립니다" }
        return panel.isVisible ? "카카오톡 광고를 가리는 중" : "카카오톡 창을 기다리는 중"
    }

    private func refreshMenuIfNeeded() {
        let title = statusTitle()
        guard title != statusItemTitle else { return }
        statusItemTitle = title
        statusItem.menu = makeMenu()
    }

    private func buildPanel() {
        let p = BandPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = false      // 광고 클릭이 그대로 먹히지 않도록 덮개가 클릭을 받는다.
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let view = BandView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.fill = .white
        p.contentView = view
        bandView = view

        let u = UsageView(frame: view.bounds)
        u.autoresizingMask = [.width, .height]
        u.isHidden = true
        view.addSubview(u)
        usageView = u

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            l.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            l.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        label = l

        panel = p
    }

    // MARK: kakao window lookup

    private func kakaoApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundleID).first
    }

    private func mainWindow(of app: AXUIElement) -> AXUIElement? {
        let windows = (axValue(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        if let titled = windows.first(where: { axString($0, kAXTitleAttribute as String) == "카카오톡" }) {
            return titled
        }
        return windows.max { (axFrame($0)?.width ?? 0) < (axFrame($1)?.width ?? 0) }
    }

    /// 채팅/친구 목록 테이블을 담고 있는 스크롤 영역의 아랫변을 찾는다.
    /// 그 아래가 광고 배너 자리다. (표 안쪽까지 들어가면 AX 호출이 폭발하므로 예산을 두고 넓게만 훑는다)
    private func chatListBottom(in window: AXUIElement) -> CGFloat? {
        var best: CGRect?
        var budget = 150
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        while !queue.isEmpty && budget > 0 {
            let (el, depth) = queue.removeFirst()
            budget -= 1
            let role = axString(el, kAXRoleAttribute as String) ?? ""
            if role == "AXTable" { continue }
            if role == "AXScrollArea", let f = axFrame(el) {
                let children = axChildren(el)
                if children.contains(where: { axString($0, kAXRoleAttribute as String) == "AXTable" }) {
                    if best == nil || f.height > best!.height { best = f }
                    continue
                }
            }
            if depth < 6 {
                for child in axChildren(el) { queue.append((child, depth + 1)) }
            }
        }
        return best?.maxY
    }

    private func hasSheet(_ window: AXUIElement) -> Bool {
        axChildren(window).contains { axString($0, kAXRoleAttribute as String) == "AXSheet" }
    }

    // MARK: tick

    private func tick() {
        guard enabled else { hidePanel(); refreshMenuIfNeeded(); return }
        if !trusted { trusted = AXIsProcessTrusted() }
        guard trusted else { hidePanel(); refreshMenuIfNeeded(); return }
        guard let app = kakaoApp() else { if panel.isVisible { log("kakao not running") }; hidePanel(); refreshMenuIfNeeded(); return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = mainWindow(of: axApp) else { hidePanel(); refreshMenuIfNeeded(); return }
        guard let wid = windowID(of: win) else { hidePanel(); refreshMenuIfNeeded(); return }

        guard !(axBool(win, kAXMinimizedAttribute as String) ?? false) else { hidePanel(); refreshMenuIfNeeded(); return }
        if hasSheet(win) { log("has sheet -> hide"); hidePanel(); refreshMenuIfNeeded(); return }
        guard let winFrame = axFrame(win) else { hidePanel(); refreshMenuIfNeeded(); return }

        // 배너 자리 = 목록 아랫변 ~ 창 아랫변 (창 크기가 그대로면 다시 재지 않는다)
        if bandHeightCache == nil || cachedWindowSize != winFrame.size {
            cachedWindowSize = winFrame.size
            bandHeightCache = nil
            if let listBottom = chatListBottom(in: win) {
                let h = winFrame.maxY - listBottom
                if h > 50 && h < winFrame.height * 0.35 { bandHeightCache = h }
            }
        }
        // 배너 자리를 재지 못하면 아무것도 덮지 않는다 (목록을 잘못 가리는 것보다 안전)
        guard let bandHeight = bandHeightCache else { hidePanel(); refreshMenuIfNeeded(); return }
        let bandAX = CGRect(x: winFrame.minX, y: winFrame.maxY - bandHeight,
                            width: winFrame.width, height: bandHeight)
        let rect = cocoaRect(fromAX: bandAX)

        let exposed = forceShow || isRectExposed(bandAX, windowID: wid)
        guard exposed else { hidePanel(); refreshMenuIfNeeded(); return }
        if rect != lastRect {
            log("band=\(bandHeight) rect=\(rect)")
            lastRect = rect
            panel.setFrame(rect, display: true)
            if abs(bandHeight - lastBandHeight) > 0.5 {
                lastBandHeight = bandHeight
                lastColorSample = .distantPast   // 높이가 바뀌면 색을 다시 잰다.
            }
        }

        if cachedColor == nil || Date().timeIntervalSince(lastColorSample) > 5 {
            lastColorSample = Date()
            if let sampled = sampleBandColor(windowID: wid, windowFrame: winFrame, bandHeight: bandHeight) {
                cachedColor = sampled
            }
        }
        bandView.fill = cachedColor ?? fallbackColor()

        if !panel.isVisible {
            applyModeContent()
            panel.orderFrontRegardless()
            log("show panel rect=\(rect) band=\(bandHeight) color=\(String(describing: cachedColor))")
        }
        refreshMenuIfNeeded()
    }

    private var lastLoggedOnScreen = false
    private func logOnScreen(wid: CGWindowID, win: CGRect, onScreen: Bool) {
        guard debug, onScreen != lastLoggedOnScreen else { return }
        lastLoggedOnScreen = onScreen
        log("window \(wid) frame=\(win) onScreen=\(onScreen)")
    }

    private func hidePanel() {
        if panel.isVisible { panel.orderOut(nil) }
        lastRect = .zero
    }

    private func applyModeContent() {
        label.isHidden = (mode != .clock && mode != .text)
        usageView.isHidden = (mode != .usage)
        if mode == .usage && usageView.payload == nil { fetchUsage() }
        switch mode {
        case .blank:
            label.stringValue = ""
        case .clock:
            label.stringValue = clockFormatter.string(from: Date())
        case .text:
            label.stringValue = customText
        case .usage:
            label.stringValue = ""
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        label.textColor = dark ? NSColor.white.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.38)
    }

    private func refreshClock() {
        guard mode == .clock, panel.isVisible else { return }
        applyModeContent()
    }

    private func fallbackColor() -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.945, alpha: 1)
    }

    /// 창을 한 장 찍어서 배너 영역에서 가장 많이 쓰인 색을 고른다.
    /// (카카오톡 테마가 밝은지 어두운지, 배경색이 정확히 무엇인지 자동으로 맞춘다.)
    private func sampleBandColor(windowID wid: CGWindowID, windowFrame: CGRect, bandHeight: CGFloat) -> NSColor? {
        guard let image = captureWindowImage(wid) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }

        let scale = CGFloat(rep.pixelsWide) / max(1, windowFrame.width)
        let top = Int((windowFrame.height - bandHeight) * scale)
        let bottom = rep.pixelsHigh
        guard top >= 0, bottom - top > 3 else { return nil }

        var counts: [UInt32: Int] = [:]
        var y = top + 2
        while y < bottom - 1 {
            var x = 2
            while x < rep.pixelsWide - 1 {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = UInt32(max(0, min(255, c.redComponent * 255)))
                    let g = UInt32(max(0, min(255, c.greenComponent * 255)))
                    let b = UInt32(max(0, min(255, c.blueComponent * 255)))
                    counts[(r & 0xF8) << 16 | (g & 0xF8) << 8 | (b & 0xF8), default: 0] += 1
                }
                x += 8
            }
            y += 8
        }
        guard let (key, _) = counts.max(by: { $0.value < $1.value }) else { return nil }

        let r = CGFloat((key >> 16) & 0xFF) / 255
        let g = CGFloat((key >> 8) & 0xFF) / 255
        let b = CGFloat(key & 0xFF) / 255

        // 화면 녹화 권한이 없으면 검은 그림이 온다 → 그럴 땐 기본색.
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if (!dark && lum < 0.5) || (dark && lum > 0.5) { return nil }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // MARK: usage fetch

    private let usageQueue = DispatchQueue(label: "io.github.bear2u.kakaobannerhider.usage")
    private var fetchInFlight = false
    private var usageTimer: Timer?

    private func startUsageLoop() {
        fetchUsage()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.fetchUsage() }
        RunLoop.main.add(t, forMode: .common)
        usageTimer = t
    }

    @objc private func refreshUsage() {
        fetchUsage(force: true)
    }

    private func fetchUsage(force: Bool = false) {
        if fetchInFlight && !force { return }
        fetchInFlight = true
        usageView.loading = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            var payload: UsagePayload?
            let script = Bundle.main.path(forResource: "usage_fetcher", ofType: "py") ?? ""
            if !script.isEmpty {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    payload = try? JSONDecoder().decode(UsagePayload.self, from: data)
                } catch {
                    payload = nil
                }
            }
            DispatchQueue.main.async {
                self.fetchInFlight = false
                self.usageView.loading = false
                if let payload { self.usageView.payload = payload }
                if self.panel?.isVisible == true { self.usageView.needsDisplay = true }
            }
        }
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        defaults.set(enabled, forKey: "enabled")
        if !enabled { hidePanel() }
        statusItemTitle = ""
        statusItem.menu = makeMenu()
        tick()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = DisplayMode(rawValue: raw) else { return }
        mode = m
        defaults.set(m.rawValue, forKey: "mode")
        statusItem.menu = makeMenu()
        applyModeContent()
    }

    @objc private func editText() {
        let alert = NSAlert()
        alert.messageText = "배너 자리에 표시할 문구"
        alert.informativeText = "광고를 가린 자리에 남길 글자를 적어 주세요."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = customText
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            customText = field.stringValue
            defaults.set(customText, forKey: "customText")
            mode = .text
            defaults.set(mode.rawValue, forKey: "mode")
            statusItem.menu = makeMenu()
            applyModeContent()
        }
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        statusItem.menu = makeMenu()
    }

    @objc private func bringKakaoForward() {
        guard let app = kakaoApp() else { return }
        app.activate(options: [.activateAllWindows])
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
