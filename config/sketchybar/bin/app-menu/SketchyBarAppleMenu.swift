import ApplicationServices
import Cocoa

private struct MenuAppearance {
  let backgroundColor: NSColor
  let borderColor: NSColor
  let foregroundColor: NSColor
  let itemName: String
  let sketchybarPath: String?

  init(arguments: [String]) {
    backgroundColor = Self.color(after: "--background-color", in: arguments)
      ?? NSColor(srgbRed: 21.0 / 255.0, green: 19.0 / 255.0, blue: 32.0 / 255.0, alpha: 241.0 / 255.0)
    borderColor = Self.color(after: "--border-color", in: arguments)
      ?? NSColor(srgbRed: 44.0 / 255.0, green: 46.0 / 255.0, blue: 52.0 / 255.0, alpha: 1)
    foregroundColor = Self.color(after: "--foreground-color", in: arguments)
      ?? NSColor(srgbRed: 248.0 / 255.0, green: 248.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    itemName = Self.value(after: "--item-name", in: arguments) ?? "apple_menu"
    sketchybarPath = Self.value(after: "--sketchybar-path", in: arguments)
      ?? Self.findSketchyBarExecutable()
  }

  private static func color(after option: String, in arguments: [String]) -> NSColor? {
    guard var value = value(after: option, in: arguments)?.lowercased() else { return nil }
    if value.hasPrefix("0x") {
      value.removeFirst(2)
    } else if value.hasPrefix("#") {
      value.removeFirst()
    }
    guard value.count == 6 || value.count == 8,
          let color = UInt32(value, radix: 16) else {
      return nil
    }

    let alpha = value.count == 8 ? CGFloat((color >> 24) & 0xff) / 255.0 : 1
    return NSColor(
      srgbRed: CGFloat((color >> 16) & 0xff) / 255.0,
      green: CGFloat((color >> 8) & 0xff) / 255.0,
      blue: CGFloat(color & 0xff) / 255.0,
      alpha: alpha
    )
  }

  private static func value(after option: String, in arguments: [String]) -> String? {
    guard let optionIndex = arguments.firstIndex(of: option),
          arguments.indices.contains(optionIndex + 1) else {
      return nil
    }
    return arguments[optionIndex + 1]
  }

  private static func findSketchyBarExecutable() -> String? {
    let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map { String($0) + "/sketchybar" }
      + ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

private final class MenuAction: NSObject {
  private let element: AXUIElement
  private let didSelect: () -> Void

  init(element: AXUIElement, didSelect: @escaping () -> Void) {
    self.element = element
    self.didSelect = didSelect
  }

  @objc func selectMenuItem(_ sender: NSMenuItem) {
    AXUIElementPerformAction(element, kAXPressAction as CFString)
    didSelect()
  }
}

private final class MenuPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

private final class MenuPanelController: NSObject, NSWindowDelegate {
  private let menu: NSMenu
  private let appearance: MenuAppearance
  private let didHide: () -> Void
  private let panel: MenuPanel
  private var menuStack: [NSMenu] = []
  private var outsideClickMonitor: Any?
  private var monitorInstallation: DispatchWorkItem?
  private var popupAnchor: NSPoint?
  private var popupVisibleFrame: NSRect?

  init(menu: NSMenu, appearance: MenuAppearance, didHide: @escaping () -> Void) {
    self.menu = menu
    self.appearance = appearance
    self.didHide = didHide
    panel = MenuPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    panel.delegate = self
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.acceptsMouseMovedEvents = true
    panel.ignoresMouseEvents = false
  }

  func show() {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    popupVisibleFrame = screen?.visibleFrame
    popupAnchor = barItemAnchor() ?? NSPoint(x: mouseLocation.x - 14, y: mouseLocation.y - 16)
    menuStack = [menu]
    renderCurrentMenu()
    installOutsideClickMonitor()
  }

  var isVisible: Bool { panel.isVisible }

  private func renderCurrentMenu() {
    guard let currentMenu = menuStack.last else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

    if menuStack.count > 1 {
      let backButton = NSButton(title: "Back", target: self, action: #selector(goBack))
      backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
      backButton.imagePosition = .imageLeft
      backButton.isBordered = false
      backButton.alignment = .left
      backButton.attributedTitle = NSAttributedString(
        string: "  Back",
        attributes: [
          .font: NSFont.menuFont(ofSize: 13),
          .foregroundColor: appearance.foregroundColor,
        ]
      )
      backButton.contentTintColor = appearance.foregroundColor
      backButton.toolTip = "Back"
      backButton.translatesAutoresizingMaskIntoConstraints = false
      backButton.widthAnchor.constraint(equalToConstant: 208).isActive = true
      backButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
      stack.addArrangedSubview(backButton)
    }

    var hasRenderedItem = false
    var lastRenderedItemWasSeparator = false
    for (index, item) in currentMenu.items.enumerated() {
      if item.isSeparatorItem {
        let hasFollowingItem = currentMenu.items.dropFirst(index + 1).contains {
          !$0.isSeparatorItem
        }
        guard hasRenderedItem, hasFollowingItem, !lastRenderedItemWasSeparator else {
          continue
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 208).isActive = true
        stack.addArrangedSubview(separator)
        lastRenderedItemWasSeparator = true
        continue
      }

      let button = NSButton(title: item.title, target: self, action: #selector(selectItem(_:)))
      button.isBordered = false
      button.alignment = .left
      button.attributedTitle = NSAttributedString(
        string: item.title,
        attributes: [
          .font: NSFont.menuFont(ofSize: 13),
          .foregroundColor: appearance.foregroundColor,
        ]
      )
      button.contentTintColor = appearance.foregroundColor
      button.tag = index
      button.isEnabled = item.isEnabled
      if item.submenu != nil {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration)
        button.imagePosition = .imageRight
      }
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 208).isActive = true
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      stack.addArrangedSubview(button)
      hasRenderedItem = true
      lastRenderedItemWasSeparator = false
    }

    let desiredSize = stack.fittingSize
    guard let visibleFrame = popupVisibleFrame,
          let anchor = popupAnchor else {
      return
    }
    let availableHeight = max(
      120,
      min(visibleFrame.height - 16, anchor.y - visibleFrame.minY - 8)
    )
    let size = NSSize(width: desiredSize.width, height: min(desiredSize.height, availableHeight))

    let contentView = NSView(frame: NSRect(origin: .zero, size: size))
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = appearance.backgroundColor.cgColor
    contentView.layer?.borderColor = appearance.borderColor.cgColor
    contentView.layer?.borderWidth = 1
    contentView.layer?.cornerRadius = 8
    contentView.layer?.cornerCurve = .continuous
    contentView.layer?.masksToBounds = true

    let documentView = FlippedView(frame: NSRect(origin: .zero, size: desiredSize))
    stack.frame = documentView.bounds
    stack.autoresizingMask = [.width]
    documentView.addSubview(stack)

    let scrollView = NSScrollView(frame: contentView.bounds)
    scrollView.autoresizingMask = [.width, .height]
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = desiredSize.height > size.height
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.documentView = documentView
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    contentView.addSubview(scrollView)

    contentView.autoresizingMask = [.width, .height]
    panel.contentView = contentView
    panel.setContentSize(size)
    panel.level = .popUpMenu
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    panel.setFrameOrigin(NSPoint(
      x: min(max(anchor.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
      y: max(visibleFrame.minY + 8, min(anchor.y - size.height, visibleFrame.maxY - size.height - 8))
    ))
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  private func barItemAnchor() -> NSPoint? {
    guard let sketchybarPath = appearance.sketchybarPath else { return nil }
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: sketchybarPath)
    task.arguments = ["--query", appearance.itemName]
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice

    do {
      try task.run()
    } catch {
      return nil
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let boundingRects = response["bounding_rects"] as? [String: Any],
          let mouseEvent = CGEvent(source: nil) else {
      return nil
    }

    let coreGraphicsMouse = mouseEvent.location
    for value in boundingRects.values {
      guard let rect = value as? [String: Any],
            let origin = rect["origin"] as? [NSNumber], origin.count == 2,
            let size = rect["size"] as? [NSNumber], size.count == 2 else {
        continue
      }

      let frame = CGRect(
        x: origin[0].doubleValue,
        y: origin[1].doubleValue,
        width: size[0].doubleValue,
        height: size[1].doubleValue
      )
      guard frame.contains(coreGraphicsMouse) else { continue }

      let appKitMouse = NSEvent.mouseLocation
      return NSPoint(
        x: appKitMouse.x + frame.minX - coreGraphicsMouse.x,
        y: appKitMouse.y - frame.maxY + coreGraphicsMouse.y
      )
    }
    return nil
  }

  private func installOutsideClickMonitor() {
    removeOutsideClickMonitor()
    let installation = DispatchWorkItem { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self] _ in
        DispatchQueue.main.async {
          guard let self, self.barItemAnchor() == nil else { return }
          self.hide()
        }
      }
    }
    monitorInstallation = installation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: installation)
  }

  private func removeOutsideClickMonitor() {
    monitorInstallation?.cancel()
    monitorInstallation = nil
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
      self.outsideClickMonitor = nil
    }
  }

  @objc private func selectItem(_ sender: NSButton) {
    guard let currentMenu = menuStack.last, currentMenu.items.indices.contains(sender.tag) else { return }
    let item = currentMenu.items[sender.tag]
    if let submenu = item.submenu {
      menuStack.append(submenu)
      renderCurrentMenu()
      return
    }
    guard let action = item.action else { return }
    NSApplication.shared.sendAction(action, to: item.target, from: item)
  }

  @objc private func goBack() {
    menuStack.removeLast()
    renderCurrentMenu()
  }

  func dismiss() {
    removeOutsideClickMonitor()
    panel.orderOut(nil)
    didHide()
    NSApplication.shared.terminate(nil)
  }

  func hide(restoreFocus: Bool = true) {
    removeOutsideClickMonitor()
    panel.orderOut(nil)
    if restoreFocus {
      didHide()
    }
  }

  func windowWillClose(_ notification: Notification) {
    NSApplication.shared.terminate(nil)
  }
}

private final class MenuBarController: NSObject, NSApplicationDelegate {
  private let appearance = MenuAppearance(arguments: ProcessInfo.processInfo.arguments)
  private var actions: [MenuAction] = []
  private var panelController: MenuPanelController?
  private var frontmostApp: NSRunningApplication?

  func applicationDidFinishLaunching(_ notification: Notification) {
    showMenu()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if panelController?.isVisible == true {
      panelController?.hide()
      return true
    }
    showMenu()
    return true
  }

  private func showMenu() {
    guard AXIsProcessTrustedWithOptions([
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary) else {
      NSLog("Accessibility permission is not granted.")
      NSApplication.shared.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "SketchyBar Apple Menu needs Accessibility access"
      alert.informativeText = "Enable SketchyBar Apple Menu in System Settings > Privacy & Security > Accessibility."
      alert.alertStyle = .warning
      alert.runModal()
      NSApplication.shared.terminate(nil)
      return
    }

    guard let workspaceFrontmostApp = NSWorkspace.shared.frontmostApplication else {
      fputs("menubar: no frontmost application.\n", stderr)
      NSApplication.shared.terminate(nil)
      return
    }

    let frontmostApp: NSRunningApplication
    if workspaceFrontmostApp.processIdentifier == ProcessInfo.processInfo.processIdentifier,
       let previousFrontmostApp = self.frontmostApp {
      frontmostApp = previousFrontmostApp
    } else {
      frontmostApp = workspaceFrontmostApp
    }

    self.frontmostApp = frontmostApp
    actions.removeAll()
    panelController?.hide(restoreFocus: false)

    let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
    let menu = makeMenu(for: appElement)
    guard menu.numberOfItems > 0 else {
      NSLog("No accessible menus for %@.", frontmostApp.localizedName ?? "frontmost application")
      fputs("menubar: no accessible menus for \(frontmostApp.localizedName ?? "frontmost application").\n", stderr)
      NSApplication.shared.terminate(nil)
      return
    }

    panelController = MenuPanelController(menu: menu, appearance: appearance) { [weak self] in
      DispatchQueue.main.async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier else {
          return
        }
        self?.frontmostApp?.activate(options: [])
      }
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    panelController?.show()
  }

  private func makeMenu(for appElement: AXUIElement) -> NSMenu {
    let menu = NSMenu()
    guard let menuBarElement = attributeValue(of: appElement, kAXMenuBarAttribute) else {
      return menu
    }

    for element in children(of: menuBarElement as! AXUIElement) {
      guard let title = title(of: element) else { continue }
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let submenu = makeSubmenu(for: element)
      if submenu.numberOfItems > 0 {
        item.submenu = submenu
      } else {
        configureAction(for: item, element: element)
      }
      menu.addItem(item)
    }
    return menu
  }

  private func makeSubmenu(for parent: AXUIElement) -> NSMenu {
    let menu = NSMenu()
    guard let container = children(of: parent).first(where: { role(of: $0) == kAXMenuRole }) else {
      return menu
    }

    for element in children(of: container) {
      guard let title = title(of: element), !title.isEmpty else {
        menu.addItem(.separator())
        continue
      }

      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let submenu = makeSubmenu(for: element)
      if submenu.numberOfItems > 0 {
        item.submenu = submenu
      } else {
        configureAction(for: item, element: element)
        item.isEnabled = isEnabled(element)
      }
      menu.addItem(item)
    }
    return menu
  }

  private func configureAction(for item: NSMenuItem, element: AXUIElement) {
    let action = MenuAction(element: element) { [weak self] in
      self?.frontmostApp?.activate(options: [])
      NSApplication.shared.terminate(nil)
    }
    actions.append(action)
    item.target = action
    item.action = #selector(MenuAction.selectMenuItem(_:))
  }

  private func children(of element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
    attributeValue(of: element, attribute) as? [AXUIElement] ?? []
  }

  private func title(of element: AXUIElement) -> String? {
    attributeValue(of: element, kAXTitleAttribute) as? String
  }

  private func role(of element: AXUIElement) -> String? {
    attributeValue(of: element, kAXRoleAttribute) as? String
  }

  private func isEnabled(_ element: AXUIElement) -> Bool {
    attributeValue(of: element, kAXEnabledAttribute) as? Bool ?? true
  }

  private func attributeValue(of element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }
}

private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let controller = MenuBarController()
application.delegate = controller
application.run()
