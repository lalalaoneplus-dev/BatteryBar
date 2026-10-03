import AppKit
import IOKit.hid
import IOKit.ps
import ServiceManagement

// MARK: - Battery data sources

struct DeviceBattery {
    let name: String
    let kind: Kind
    let percent: Int?   // nil = device doesn't report battery
    enum Kind: String { case keyboard = "Keyboard", mouse = "Mouse", other = "Device" }
}

enum BatterySource {

    // Private API used by `pmset -g accps`; type 4 = accessory sources only.
    private static let copyByType: (@convention(c) (Int32) -> Unmanaged<CFArray>?)? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let sym = dlsym(h, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    }()

    static func accessorySources() -> [[String: Any]] {
        guard let fn = copyByType,
              let arr = fn(4)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr
    }

    // Bluetooth HID devices currently attached (no TCC permission needed for enumeration).
    static func bluetoothHIDDevices() -> [(name: String, kind: DeviceBattery.Kind, hidBatteryPercent: Int?)] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, nil)
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
        var seen = Set<String>()
        var out: [(String, DeviceBattery.Kind, Int?)] = []
        for dev in devices {
            func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(dev, key as CFString) }
            guard let transport = prop(kIOHIDTransportKey) as? String,
                  transport.lowercased().contains("bluetooth") else { continue }
            guard let name = prop(kIOHIDProductKey) as? String, !seen.contains(name) else { continue }
            let usagePage = prop(kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
            var kind = DeviceBattery.Kind.other
            if usagePage == kHIDPage_GenericDesktop {
                if usage == kHIDUsage_GD_Keyboard { kind = .keyboard }
                else if usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer { kind = .mouse }
            }
            guard kind != .other else { continue }
            seen.insert(name)
            let pct = prop("BatteryPercent") as? Int
            out.append((name, kind, pct))
        }
        return out
    }

    static func snapshot() -> [DeviceBattery] {
        let accessories = accessorySources()
        var result: [DeviceBattery] = []
        var accessoryNamesUsed = Set<String>()

        for hid in bluetoothHIDDevices() {
            // Prefer the accessory power source (what the Bluetooth menu shows).
            let match = accessories.first { acc in
                let accName = acc["Name"] as? String ?? ""
                let accCat = acc["Accessory Category"] as? String ?? ""
                return accName == hid.name || accCat == hid.kind.rawValue
            }
            var pct: Int? = nil
            if let match, let cap = match["Current Capacity"] as? Int {
                pct = cap
                accessoryNamesUsed.insert(match["Name"] as? String ?? "")
            } else {
                pct = hid.hidBatteryPercent
            }
            result.append(DeviceBattery(name: hid.name, kind: hid.kind, percent: pct))
        }

        // Any battery-reporting accessory not matched to a HID device (safety net).
        for acc in accessories {
            guard let name = acc["Name"] as? String,
                  !accessoryNamesUsed.contains(name),
                  !result.contains(where: { $0.name == name }),
                  let cap = acc["Current Capacity"] as? Int else { continue }
            let cat = acc["Accessory Category"] as? String ?? ""
            let kind: DeviceBattery.Kind = cat == "Keyboard" ? .keyboard : cat == "Mouse" ? .mouse : .other
            result.append(DeviceBattery(name: name, kind: kind, percent: cap))
        }

        // Stable order: keyboards first, then mice, then others.
        let order: [DeviceBattery.Kind] = [.keyboard, .mouse, .other]
        result.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return result
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()

        // React to power-source changes (accessory battery updates) + periodic fallback.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.refresh() }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func symbol(for kind: DeviceBattery.Kind) -> NSImage? {
        let name: String
        switch kind {
        case .keyboard: name = "keyboard"
        case .mouse: name = "computermouse.fill"
        case .other: name = "battery.75percent"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: kind.rawValue)
        img?.isTemplate = true
        return img
    }

    func refresh() {
        let devices = BatterySource.snapshot()
        NSLog("BatteryBar snapshot: %@", devices.map { "\($0.name)[\($0.kind.rawValue)]=\($0.percent.map(String.init) ?? "–")" }.joined(separator: ", "))

        let title = NSMutableAttributedString()
        let font = NSFont.menuBarFont(ofSize: 0)
        for (i, dev) in devices.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ")) }
            if let img = symbol(for: dev.kind) {
                let att = NSTextAttachment()
                att.image = img
                let h = font.capHeight
                att.bounds = CGRect(x: 0, y: (h - 14) / 2 + 1, width: 18, height: 14)
                title.append(NSAttributedString(attachment: att))
            }
            let pctText = dev.percent.map { " \($0)%" } ?? " –"
            title.append(NSAttributedString(string: pctText, attributes: [.font: font]))
        }
        if devices.isEmpty {
            title.append(NSAttributedString(string: "No BT input devices", attributes: [.font: font]))
        }
        statusItem.button?.attributedTitle = title
    }

    // Rebuild the dropdown each time it opens so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        for dev in BatterySource.snapshot() {
            let text: String
            if let p = dev.percent {
                text = "\(dev.name) (\(dev.kind.rawValue)) — \(p)%"
            } else {
                text = "\(dev.name) (\(dev.kind.rawValue)) — battery not reported by device"
            }
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.image = symbol(for: dev.kind)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BatteryBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("BatteryBar login toggle failed: %@", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
