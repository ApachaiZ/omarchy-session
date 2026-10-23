import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "apach.session"
  ipcTarget: "apach.session"
  manageIpc: false

  property var displays: []
  property int enabledDisplayCount: 0
  property var profiles: []

  // "main" | "displays" | "placement"
  property string view: "main"

  // Where this widget sits in shell.json, read for the placement view.
  property string barSection: ""
  property int barIndex: -1
  property var barSizes: ({ left: 0, center: 0, right: 0 })

  // Deferred placement: the placement view edits this locally. Applying it with
  // `omarchy bar move` rebuilds the bar (and therefore this widget), so moving
  // only happens when the user leaves the view; the panel then stays open for
  // as many section/order changes as they want.
  property string pendingSection: ""
  property int pendingIndex: -1
  property bool pendingTouched: false
  property bool placementCommitting: false
  readonly property bool hasPendingPlacement: pendingSection !== "" && pendingIndex >= 0
  readonly property bool placementDirty: pendingTouched
    && (pendingSection !== barSection || pendingIndex !== barIndex)

  // Real identity and uptime for the title subtitle.
  readonly property string shellConfigPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/shell.json"
  property string hostName: Quickshell.env("HOSTNAME") || Quickshell.env("HOST") || "localhost"
  property string uptimeText: "—"
  property bool hibernateAvailable: false
  property bool hibernateProbed: false

  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  readonly property string identityText: (root.userName !== "" ? root.userName + "@" : "") + root.hostName

  readonly property var screenActions: [
    { icon: "󰌾", label: "Lock", command: ["omarchy-system-lock"] },
    { icon: "󰍹", label: "Screen Off", command: ["omarchy-brightness-display", "off"] },
    { icon: "󱄄", label: "Screensaver", command: ["omarchy-launch-screensaver", "force"] }
  ]

  readonly property var powerSecondaryActions: [
    { icon: "󰍃", label: "Log Out", command: ["omarchy-system-logout"] },
    { icon: "󰤁", label: "Hibernate", key: "hibernate", command: ["systemctl", "hibernate"] },
    { icon: "󰒲", label: "Sleep", command: ["systemctl", "suspend"] }
  ]

  // The two session-ending actions get the full-width row: Shutdown and Reboot
  // use Omarchy's own menu labels.
  readonly property var powerPrimaryActions: [
    { icon: "󰐥", label: "Shutdown", command: ["omarchy-system-shutdown"] },
    { icon: "󰜉", label: "Reboot", command: ["omarchy-system-reboot"] }
  ]

  readonly property var barSections: [
    { id: "left", label: "Left" },
    { id: "center", label: "Center" },
    { id: "right", label: "Right" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshDisplays() {
    if (!monitorsProc.running) monitorsProc.running = true
  }

  function refreshProfiles() {
    if (!profilesProc.running) profilesProc.running = true
  }

  function isBarSection(section) {
    var target = String(section || "")
    for (var i = 0; i < root.barSections.length; i++) {
      if (root.barSections[i].id === target) return true
    }
    return false
  }

  function refreshPlacement() {
    placementFile.reload()
  }

  function applyPlacement(raw) {
    var placement = Model.parseBarPlacement(raw, root.moduleName)
    root.barSection = placement.section
    root.barIndex = placement.index
    root.barSizes = placement.sizes
    // Keystrokes in the placement view own the pending values; any other
    // shell.json update (or the first load) refreshes them.
    if (!root.pendingTouched) {
      root.pendingSection = root.barSection
      root.pendingIndex = root.barIndex
    }
  }

  // `omarchy bar move` persists shell.json and lets the running shell hot-reload
  // the new layout, so the widget does not need to write config itself.
  function moveBar(section, index) {
    if (barMoveProc.running) return
    var target = String(section || "")
    if (!root.isBarSection(target)) return
    var size = Number(root.barSizes[target] || 0)
    var at = Math.max(0, Math.min(Math.round(Number(index) || 0), size))
    root.placementCommitting = true
    barMoveProc.command = [ "omarchy", "bar", "move", root.moduleName, "--section", target, "--index", String(at) ]
    barMoveProc.running = true
  }

  // Entries the target section will hold once this widget joins it. A different
  // section gains one slot; its current index is the append position.
  function pendingTotal(section) {
    var target = String(section || "")
    if (!root.isBarSection(target)) return 0
    var size = Number(root.barSizes[target] || 0)
    if (root.barSection !== "" && target !== root.barSection) size += 1
    return size
  }

  function loadPendingPlacement() {
    root.pendingTouched = false
    root.pendingSection = root.barSection
    root.pendingIndex = root.barIndex
  }

  // Changing section appends, like the notification center's placement view;
  // the order stepper then refines the exact index. Nothing is written until
  // the placement view is left.
  function moveBarSection(section) {
    var target = String(section || "")
    if (!root.isBarSection(target)) return
    if (root.pendingSection !== target) {
      root.pendingSection = target
      root.pendingIndex = target === root.barSection
        ? root.barIndex
        : Number(root.barSizes[target] || 0)
    }
    root.pendingTouched = true
  }

  function stepPendingIndex(delta) {
    if (!root.hasPendingPlacement) return
    var total = root.pendingTotal(root.pendingSection)
    if (total <= 0) return
    root.pendingIndex = Math.max(0, Math.min(root.pendingIndex + delta, total - 1))
    root.pendingTouched = true
  }

  function commitPendingPlacement() {
    if (root.placementCommitting || !root.placementDirty) return
    root.moveBar(root.pendingSection, root.pendingIndex)
  }

  function setDisplayMode(name, mode) {
    var safe = Model.safeName(name)
    if (!safe || !mode) return
    var expr = 'hl.monitor({ output = "' + safe + '", mode = "' + mode + '", position = "auto" })'
    monitorApplyProc.command = [ "hyprctl", "eval", expr ]
    monitorApplyProc.running = true
  }

  function setTransform(name, transform) {
    var safe = Model.safeName(name)
    if (!safe) return
    var expr = 'hl.monitor({ output = "' + safe + '", transform = ' + transform + ', position = "auto" })'
    monitorApplyProc.command = [ "hyprctl", "eval", expr ]
    monitorApplyProc.running = true
  }

  function setDisplayEnabled(name, enabled) {
    var safe = Model.safeName(name)
    if (!safe) return
    var next = enabled === true
    if (!next && root.enabledDisplayCount <= 1) return
    var expr = next
      ? 'hl.monitor({ output = "' + safe + '", disabled = false, mode = "preferred", position = "auto", scale = "auto" })'
      : 'hl.monitor({ output = "' + safe + '", disabled = true })'
    monitorApplyProc.command = [ "hyprctl", "eval", expr ]
    monitorApplyProc.running = true
  }

  function runAction(command) {
    if (!command || command.length === 0 || actionProc.running) return
    actionProc.command = command
    actionProc.running = true
    root.close()
  }

  function setProfile(name) {
    profileSetProc.command = [ "powerprofilesctl", "set", name ]
    profileSetProc.running = true
  }

  function openDisplays() {
    root.view = "displays"
    root.refreshDisplays()
  }
  function openPlacement() {
    root.view = "placement"
    root.refreshPlacement()
    root.loadPendingPlacement()
  }
  function backToSession() {
    if (root.view === "placement") root.commitPendingPlacement()
    root.view = "main"
  }

  // SUPER+E toggles the panel and SUPER+M opens Displays; the gear opens the
  // placement view. The IPC methods exist for keyboard binds without a gear.
  IpcHandler {
    target: "apach.session"
    function toggle() { root.toggle() }
    function displays() {
      root.open()
      root.openDisplays()
    }
    function settings() {
      root.open()
      root.view = "placement"
      root.refreshPlacement()
      root.loadPendingPlacement()
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.view = "main"
      root.refreshProfiles()
      if (!root.hibernateProbed) {
        root.hibernateProbed = true
        hibernateProbe.running = true
      }
    } else {
      root.commitPendingPlacement()
    }
  }

  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!uptimeProc.running) uptimeProc.running = true
  }

  Process {
    id: monitorsProc
    command: [ "hyprctl", "monitors", "-j" ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.displays = Model.parseMonitors(String(text || ""))
        root.enabledDisplayCount = 0
        for (var i = 0; i < root.displays.length; i++) {
          if (root.displays[i].enabled) root.enabledDisplayCount++
        }
      }
    }
  }

  Process {
    id: monitorApplyProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refreshDisplays()
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: profilesProc
    command: [ "omarchy-powerprofiles-list", "--active-state" ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.profiles = Model.parseProfiles(String(text || ""))
      }
    }
  }

  Process {
    id: profileSetProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refreshProfiles()
  }

  Process {
    id: uptimeProc
    command: [ "cat", "/proc/uptime" ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.uptimeText = Model.formatUptime(Model.parseUptime(String(text || "")))
      }
    }
  }

  Process {
    id: hibernateProbe
    command: [ "omarchy-hibernation-available" ]
    onExited: function(exitCode) { root.hibernateAvailable = exitCode === 0 }
  }

  Process {
    id: barMoveProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.placementCommitting = false
      if (exitCode === 0) root.pendingTouched = false
      root.refreshPlacement()
    }
  }

  FileView {
    id: placementFile
    path: root.shellConfigPath
    watchChanges: root.opened && root.view === "placement"
    atomicWrites: false
    printErrors: false
    onLoaded: root.applyPlacement(text())
    onFileChanged: reload()
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var name = String(text() || "").trim()
      if (name !== "") root.hostName = name
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐥"
    onPressed: function(b) { root.toggle() }
  }

  // ---------- Main panel: Screen + Power + Power Profile + Displays entry ----------
  KeyboardPanel {
    id: mainPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.view === "main"
    contentWidth: mainPanel.fittedContentWidth(Style.space(400))
    contentHeight: mainPanel.fittedContentHeight(mainColumn.implicitHeight, Style.space(620))

    Column {
      id: mainColumn
      anchors.fill: parent
      spacing: Style.space(12)

      // Centered identity header. The gear sits in the right gutter, outside
      // the centered block, so the title stays optically centered.
      Item {
        width: parent.width
        height: titleBlock.implicitHeight

        Column {
          id: titleBlock
          width: parent.width - placementButton.width - Style.space(12)
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(2)

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Text {
              text: "󰐥"
              color: Commons.Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: "Session"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }

          Text {
            width: parent.width
            text: root.identityText + "  —  up " + root.uptimeText
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.5
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          id: placementButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒓"
          tooltipText: "Bar placement"
          foreground: root.bar.foreground
          hoverColor: Commons.Color.accent
          fontFamily: root.bar.fontFamily
          focusable: true
          onClicked: root.openPlacement()
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        width: parent.width
      }

      PanelSectionHeader {
        text: "SCREEN"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Grid {
        id: screenGrid
        width: parent.width
        columns: 3
        columnSpacing: Style.space(6)
        rowSpacing: Style.space(6)

        readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns

        Repeater {
          model: root.screenActions

          Button {
            required property var modelData

            width: screenGrid.cellWidth
            text: modelData.label
            iconText: modelData.icon
            fontSize: Style.font.bodySmall
            iconSize: Style.font.body
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            focusable: true
            onClicked: root.runAction(modelData.command)
          }
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        width: parent.width
      }

      PanelSectionHeader {
        text: "POWER"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Grid {
          id: powerGrid
          width: parent.width
          columns: 3
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)

          readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns

          Repeater {
            model: root.powerSecondaryActions

            Button {
              required property var modelData

              readonly property bool available: modelData.key !== "hibernate" || root.hibernateAvailable

              width: powerGrid.cellWidth
              text: modelData.label
              iconText: modelData.icon
              fontSize: Style.font.bodySmall
              iconSize: Style.font.body
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: available
              opacity: available ? 1 : 0.45
              tooltipText: available ? "" : "Hibernation is not available on this system"
              focusable: available
              onClicked: root.runAction(modelData.command)
            }
          }
        }

        Grid {
          id: powerSystemGrid
          width: parent.width
          columns: 2
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)

          readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns

          Repeater {
            model: root.powerPrimaryActions

            Button {
              required property var modelData

              width: powerSystemGrid.cellWidth
              text: modelData.label
              iconText: modelData.icon
              fontSize: Style.font.bodySmall
              iconSize: Style.font.body
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              focusable: true
              onClicked: root.runAction(modelData.command)
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        width: parent.width
      }

      PanelSectionHeader {
        text: "POWER PROFILE"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Row {
        id: profileRow
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.profiles

          Button {
            required property var modelData
            required property int index

            width: root.profiles.length > 0 ? (profileRow.width - profileRow.spacing * (root.profiles.length - 1)) / root.profiles.length : 0
            text: modelData.label
            fontSize: Style.font.caption
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            active: modelData.active
            focusable: true
            onClicked: root.setProfile(modelData.name)
          }
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        width: parent.width
      }

      // "Displays" navigation entry (label left, chevron right)
      BorderSurface {
        id: displaysEntry
        width: parent.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        activeFocusOnTab: true
        readonly property bool hot: entryHover.hovered || displaysEntry.activeFocus
        color: hot ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"
        borderSpec: Border.controlSpec(displaysEntry.activeFocus ? "focus" : (entryHover.hovered ? "hover-cursor" : "normal"), root.bar.foreground, Commons.Color.accent)
        Keys.onReturnPressed: root.openDisplays()
        Keys.onEnterPressed: root.openDisplays()
        Keys.onSpacePressed: root.openDisplays()

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.rightMargin: Style.spacing.controlGap
          spacing: Style.spacing.controlGap

          Text {
            text: "Displays"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width - displaysChevron.implicitWidth - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: displaysChevron
            text: "󰅂"
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        HoverHandler { id: entryHover }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            displaysEntry.forceActiveFocus()
            root.openDisplays()
          }
        }
      }

      Item {
        width: parent.width
        height: Style.space(4)
      }
    }
  }

  // ---------- Placement panel ----------
  KeyboardPanel {
    id: placementPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.view === "placement"
    contentWidth: placementPanel.fittedContentWidth(Style.space(400))
    contentHeight: placementPanel.fittedContentHeight(placementColumn.implicitHeight, Style.space(560))

    Column {
      id: placementColumn
      anchors.fill: parent
      spacing: Style.space(12)

      Button {
        width: parent.width
        leftAlign: true
        iconText: "󰅁"
        text: "Back"
        fontSize: Style.font.body
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        focusable: true
        onClicked: root.backToSession()
      }

      Item {
        width: parent.width
        height: placementTitle.implicitHeight

        Text {
          id: placementTitle
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Bar placement"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        width: parent.width
      }

      PanelSectionHeader {
        text: "SECTION"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Row {
        id: sectionRow
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.barSections

          Button {
            required property var modelData

            width: (sectionRow.width - sectionRow.spacing * 2) / 3
            text: modelData.label
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            focusable: true
            selected: root.pendingSection === modelData.id
            onClicked: root.moveBarSection(modelData.id)
          }
        }
      }

      PanelSectionHeader {
        text: "ORDER IN SECTION"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        PanelActionButton {
          iconText: "‹"
          tooltipText: "Move earlier"
          focusable: true
          foreground: root.bar.foreground
          hoverColor: Commons.Color.accent
          fontFamily: root.bar.fontFamily
          enabled: root.hasPendingPlacement && root.pendingIndex > 0
          onClicked: root.stepPendingIndex(-1)
        }

        Text {
          width: Style.space(64)
          anchors.verticalCenter: parent.verticalCenter
          text: !root.hasPendingPlacement
            ? "—"
            : (root.pendingIndex + 1) + " / " + root.pendingTotal(root.pendingSection)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        PanelActionButton {
          iconText: "›"
          tooltipText: "Move later"
          focusable: true
          foreground: root.bar.foreground
          hoverColor: Commons.Color.accent
          fontFamily: root.bar.fontFamily
          enabled: root.hasPendingPlacement
            && root.pendingIndex >= 0
            && root.pendingIndex < root.pendingTotal(root.pendingSection) - 1
          onClicked: root.stepPendingIndex(1)
        }
      }

      Text {
        width: parent.width
        text: !root.hasPendingPlacement
          ? "Session is not on the bar."
          : root.placementDirty
            ? "Pending: " + (root.pendingIndex + 1) + " of " + root.pendingTotal(root.pendingSection)
              + " in the " + root.pendingSection + " section. Applied when you leave this view."
            : "Session is " + (root.pendingIndex + 1) + " of " + root.pendingTotal(root.pendingSection)
              + " in the " + root.pendingSection + " section."
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Item {
        width: parent.width
        height: Style.space(4)
      }
    }
  }

  // ---------- Displays panel ----------
  KeyboardPanel {
    id: displaysPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.view === "displays"
    contentWidth: displaysPanel.fittedContentWidth(Style.space(400))
    contentHeight: displaysPanel.fittedContentHeight(displaysColumn.implicitHeight, Style.space(620))

    ScrollView {
      id: displaysScroll
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: displaysColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      Binding {
        target: displaysScroll.contentItem
        property: "interactive"
        value: displaysColumn.implicitHeight > displaysScroll.height
      }

      Column {
        id: displaysColumn
        width: displaysScroll.availableWidth
        spacing: Style.space(12)

        Button {
          width: parent.width
          leftAlign: true
          iconText: "󰅁"
          text: "Back"
          fontSize: Style.font.body
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          focusable: true
          onClicked: root.backToSession()
        }

        Text {
          text: "Displays"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.displays.length === 0 ? "No displays detected" : (root.displays.length + " display(s)")
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
        }

        Repeater {
          model: root.displays

          delegate: Column {
            required property var modelData
            required property int index

            readonly property var display: modelData

            width: displaysColumn.width
            spacing: Style.space(8)

            PanelSeparator {
              visible: index > 0
              foreground: root.bar.foreground
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: display.name + (display.focused ? "  ·  focused" : "") + (display.enabled ? "" : "  ·  off")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Dropdown {
              width: parent.width
              label: "Mode"
              value: Model.currentModeValue(display)
              options: display.modes
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.setDisplayMode(display.name, v) }
            }

            Item {
              width: parent.width
              height: rotationLabel.implicitHeight + Style.space(6) + rotationRow.implicitHeight

              Text {
                id: rotationLabel
                text: "Rotation"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
              }

              Row {
                id: rotationRow
                width: parent.width
                anchors.top: rotationLabel.bottom
                anchors.topMargin: Style.space(6)
                spacing: Style.space(6)

                Repeater {
                  model: [ "0°", "90°", "180°", "270°" ]

                  Button {
                    required property string modelData
                    required property int index

                    width: (rotationRow.width - rotationRow.spacing * 3) / 4
                    text: modelData
                    fontSize: Style.font.caption
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    bordered: true
                    focusable: true
                    active: index === display.transform
                    onClicked: root.setTransform(display.name, index)
                  }
                }
              }
            }

            Toggle {
              width: parent.width
              label: "Enabled"
              checked: display.enabled
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.setDisplayEnabled(display.name, !display.enabled)
            }
          }
        }

        Item {
          width: parent.width
          height: Style.space(4)
        }
      }
    }
  }
}
