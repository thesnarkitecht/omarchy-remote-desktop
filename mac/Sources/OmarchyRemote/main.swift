// Omarchy Remote: native macOS viewer for an Omarchy (Hyprland) desktop.
// Logs in over SSH with your Omarchy username and password, and tunnels to wayvnc on 127.0.0.1:5900.
import AppKit
import RFB

// ssh asks for the password by running this same binary as its SSH_ASKPASS helper.
if let pw = ProcessInfo.processInfo.environment["OMARCHY_REMOTE_PASSWORD"], CommandLine.arguments.count == 2 {
    print(pw)
    exit(0)
}

// MARK: - SSH tunnel

final class Tunnel {
    let process = Process()
    let port: Int
    private let stderr = Pipe()

    init(target: String, password: String) throws {
        port = Tunnel.freePort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["OMARCHY_REMOTE_PASSWORD"] = password
        process.environment = env
        process.arguments = [
            "-N", "-o", "NumberOfPasswordPrompts=1", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "127.0.0.1:\(port):127.0.0.1:5900", "--", target,
        ]
        process.standardError = stderr
        try process.run()
    }

    /// Wait for the forward to come up, then speak RFB through it.
    func connect() throws -> RFBConnection {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                let msg = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if msg.contains("Permission denied") { throw RFBError.connect("wrong username or password") }
                throw RFBError.connect("ssh exited: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            do {
                return try RFBConnection(host: "127.0.0.1", port: port)
            } catch RFBError.connect {
                Thread.sleep(forTimeInterval: 0.2) // ssh not listening yet
            } catch RFBError.closed {
                throw RFBError.connect("SSH works, but nothing is listening on the remote's port 5900. On the Omarchy machine run: systemctl --user restart omarchy-remote")
            }
        }
        throw RFBError.connect("timed out waiting for the SSH tunnel")
    }

    func stop() { if process.isRunning { process.terminate() } }

    private static func freePort() -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

// MARK: - Remote view

final class RemoteView: NSView {
    var conn: RFBConnection?
    var fbWidth: CGFloat = 1, fbHeight: CGFloat = 1
    private var buttons: UInt8 = 0
    private var lastX = 0, lastY = 0
    private var scrollX: CGFloat = 0, scrollY: CGFloat = 0
    private var pressedKeys: [UInt16: UInt32] = [:]
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// Copy the framebuffer into an sRGB-tagged image so macOS colour-manages it correctly
    /// (untagged pixels get stretched to the display gamut and look oversaturated or flat).
    func present() {
        guard let conn else { return }
        conn.lock.lock()
        let w = conn.width, h = conn.height
        let data = conn.pixels.withUnsafeBytes { Data($0) }
        conn.lock.unlock()
        guard w > 0, h > 0, let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: sRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        fbWidth = CGFloat(w); fbHeight = CGFloat(h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    // MARK: pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    // The remote draws its own cursor into the frame; a small dot shows where ours is without doubling up.
    private static let dot: NSCursor = {
        let img = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { r in
            NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
            NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 3, y: 3))
    }()

    override func cursorUpdate(with event: NSEvent) { Self.dot.set() }

    private func sendPointer(_ e: NSEvent, extra: UInt8 = 0) {
        let p = convert(e.locationInWindow, from: nil)
        let s = min(bounds.width / fbWidth, bounds.height / fbHeight)
        let x = (p.x - (bounds.width - fbWidth * s) / 2) / s
        let y = (bounds.height - p.y - (bounds.height - fbHeight * s) / 2) / s
        lastX = Int(min(max(x, 0), fbWidth - 1)); lastY = Int(min(max(y, 0), fbHeight - 1))
        conn?.sendPointer(x: lastX, y: lastY, mask: buttons | extra)
    }

    private func press(_ bit: UInt8, _ e: NSEvent) { buttons |= bit; sendPointer(e) }
    private func release(_ bit: UInt8, _ e: NSEvent) { buttons &= ~bit; sendPointer(e) }

    override func mouseDown(with e: NSEvent) { press(1, e) }
    override func mouseUp(with e: NSEvent) { release(1, e) }
    override func rightMouseDown(with e: NSEvent) { press(4, e) }
    override func rightMouseUp(with e: NSEvent) { release(4, e) }
    override func otherMouseDown(with e: NSEvent) { press(2, e) }
    override func otherMouseUp(with e: NSEvent) { release(2, e) }
    override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    override func otherMouseDragged(with e: NSEvent) { sendPointer(e) }

    override func scrollWheel(with e: NSEvent) {
        // Trackpads report pixels; turn every ~16pt into one wheel click. Follows the Mac's natural-scrolling setting.
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 16 : 1
        scrollY += e.scrollingDeltaY
        scrollX += e.scrollingDeltaX
        func click(_ bit: UInt8) { sendPointer(e, extra: bit); sendPointer(e) }
        while scrollY >= step { click(8); scrollY -= step }
        while scrollY <= -step { click(16); scrollY += step }
        while scrollX >= step { click(32); scrollX -= step }
        while scrollX <= -step { click(64); scrollX += step }
        if e.phase == .ended || e.momentumPhase == .ended { scrollX = 0; scrollY = 0 }
    }

    // MARK: keyboard (X11 keysyms). Cmd -> Super so Hyprland bindings work.

    private static let special: [UInt16: UInt32] = [
        36: 0xFF0D, 48: 0xFF09, 51: 0xFF08, 53: 0xFF1B, 117: 0xFFFF, 76: 0xFF8D, 114: 0xFF63,
        123: 0xFF51, 124: 0xFF53, 125: 0xFF54, 126: 0xFF52,
        115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56,
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,
    ]

    private static let modifiers: [UInt16: (UInt32, NSEvent.ModifierFlags)] = [
        56: (0xFFE1, .shift), 60: (0xFFE2, .shift),
        59: (0xFFE3, .control), 62: (0xFFE4, .control),
        58: (0xFFE9, .option), 61: (0xFFEA, .option),
        55: (0xFFEB, .command), 54: (0xFFEC, .command),
    ]

    private static func keysym(_ e: NSEvent) -> UInt32? {
        if let k = special[e.keyCode] { return k }
        guard let v = e.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return nil }
        if (0x20...0x7E).contains(v) || (0xA0...0xFF).contains(v) { return v }
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) { return nil }
        return 0x0100_0000 + v
    }

    func handleKey(_ e: NSEvent) {
        guard let conn else { return }
        switch e.type {
        case .keyDown:
            guard !e.isARepeat, let k = Self.keysym(e) else { return } // the remote does its own key repeat
            pressedKeys[e.keyCode] = k
            conn.sendKey(k, down: true)
        case .keyUp:
            if let k = pressedKeys.removeValue(forKey: e.keyCode) { conn.sendKey(k, down: false) }
        case .flagsChanged:
            if e.keyCode == 57 { conn.sendKey(0xFFE5, down: true); conn.sendKey(0xFFE5, down: false); return }
            guard let (k, flag) = Self.modifiers[e.keyCode] else { return }
            if e.modifierFlags.contains(flag) && pressedKeys[e.keyCode] == nil {
                pressedKeys[e.keyCode] = k
                conn.sendKey(k, down: true)
            } else if pressedKeys.removeValue(forKey: e.keyCode) != nil {
                conn.sendKey(k, down: false)
            }
        default: break
        }
    }

    /// Avoid stuck keys (e.g. Super held) when focus leaves the window.
    func releaseAll() {
        for k in pressedKeys.values { conn?.sendKey(k, down: false) }
        pressedKeys.removeAll()
        if buttons != 0 { buttons = 0; conn?.sendPointer(x: lastX, y: lastY, mask: 0) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var view: RemoteView?
    var conn: RFBConnection?
    var tunnel: Tunnel?
    var lastPasteboard = NSPasteboard.general.changeCount
    private let frameLock = NSLock()
    private var framePending = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow, let v = self.view else { return e }
            v.handleKey(e) // swallow everything, including Cmd shortcuts, so they reach Hyprland
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        prompt()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { teardown() }

    func prompt(error: String? = nil) {
        let alert = NSAlert()
        alert.messageText = error == nil ? "Connect to Omarchy" : "Connection failed"
        alert.informativeText = error ?? "Your Omarchy login."
        func field(_ f: NSTextField, _ placeholder: String, _ key: String) -> NSTextField {
            f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            f.placeholderString = placeholder
            f.stringValue = UserDefaults.standard.string(forKey: key) ?? ""
            return f
        }
        let host = field(NSTextField(), "Computer (e.g. 192.168.1.20)", "host")
        let user = field(NSTextField(), "Username", "user")
        let pass = field(NSSecureTextField(), "Password", "-")
        let stack = NSStackView(views: [host, user, pass])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 88)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Quit")
        alert.window.initialFirstResponder = host.stringValue.isEmpty ? host : pass
        host.nextKeyView = user; user.nextKeyView = pass; pass.nextKeyView = host
        guard alert.runModal() == .alertFirstButtonReturn else { return NSApp.terminate(nil) }
        let h = host.stringValue.trimmingCharacters(in: .whitespaces), u = user.stringValue.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !u.isEmpty, !u.hasPrefix("-"), !h.hasPrefix("-"), !(h + u).contains(where: { $0.isWhitespace || $0 == "@" }) else {
            return prompt(error: "Enter the computer's address and your username.")
        }
        UserDefaults.standard.set(h, forKey: "host")
        UserDefaults.standard.set(u, forKey: "user")
        connect("\(u)@\(h)", password: pass.stringValue)
    }

    func connect(_ target: String, password: String) {
        DispatchQueue.global().async {
            do {
                let tunnel = try Tunnel(target: target, password: password)
                do {
                    let conn = try tunnel.connect()
                    DispatchQueue.main.async { self.open(conn, tunnel, title: target) }
                } catch { tunnel.stop(); throw error }
            } catch {
                DispatchQueue.main.async { self.prompt(error: "\(error)") }
            }
        }
    }

    func open(_ conn: RFBConnection, _ tunnel: Tunnel, title: String) {
        self.conn = conn; self.tunnel = tunnel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // One remote pixel per Mac physical pixel when it fits: sharpest possible picture.
        var size = NSSize(width: CGFloat(conn.width) / screen.backingScaleFactor, height: CGFloat(conn.height) / screen.backingScaleFactor)
        let fit = min(1, screen.visibleFrame.width / size.width, (screen.visibleFrame.height - 40) / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "\(title) — \(conn.name)"
        w.collectionBehavior = [.fullScreenPrimary]
        w.contentAspectRatio = NSSize(width: conn.width, height: conn.height)
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let v = RemoteView(frame: NSRect(origin: .zero, size: size))
        v.conn = conn
        w.contentView = v
        w.center()
        window = w; view = v

        conn.onFrame = { [weak self] in self?.scheduleFrame() }
        conn.onResize = { [weak self] in
            DispatchQueue.main.async { if let c = self?.conn { self?.window?.contentAspectRatio = NSSize(width: c.width, height: c.height) } }
        }
        conn.onClipboard = { [weak self] text in
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self?.lastPasteboard = pb.changeCount
            }
        }
        conn.onClose = { [weak self] err in
            DispatchQueue.main.async {
                guard let self, self.conn === conn else { return }
                self.teardown()
                self.prompt(error: "Disconnected: \(err)")
            }
        }
        conn.start()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
    }

    /// Coalesce frames so a slow main thread never builds up a backlog.
    private func scheduleFrame() {
        frameLock.lock(); defer { frameLock.unlock() }
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async {
            self.frameLock.lock(); self.framePending = false; self.frameLock.unlock()
            self.view?.present()
        }
    }

    func teardown() {
        conn?.disconnect(); conn = nil
        tunnel?.stop(); tunnel = nil
        let w = window
        window = nil; view = nil
        w?.close()
    }

    func windowDidBecomeKey(_ n: Notification) {
        let pb = NSPasteboard.general
        if pb.changeCount != lastPasteboard, let s = pb.string(forType: .string) { conn?.sendClipboard(s) }
        lastPasteboard = pb.changeCount
    }

    func windowDidResignKey(_ n: Notification) { view?.releaseAll() }

    func windowWillClose(_ n: Notification) {
        guard window != nil else { return } // closed by teardown()
        teardown()
        prompt()
    }

    @objc func disconnect() {
        if window != nil { teardown(); prompt() }
    }

    private func buildMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Omarchy Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit") // so Cmd-V works in the connect dialog
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        for m in [app, edit, view] {
            let item = NSMenuItem()
            item.submenu = m
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
