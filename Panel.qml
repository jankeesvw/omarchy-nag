import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Nag: disposable alarms, set from one text field.
//
// Type "15:15 pick up the kids" and it is set. The point is that setting an
// alarm costs one line and leaves nothing behind, which is what a calendar
// entry cannot do: an appointment for picking up the kids at quarter past
// three today survives in perpetuity and syncs to every device you own.
//
// bin/nag owns every bit of the parsing, so this file never has to know what a
// valid time looks like, and the preview under the field is the same code path
// that will run when Enter is pressed.
//
// KeyboardPanel rather than PopupCard, because PopupCard is a PopupWindow and
// those never get keyboard focus on Wayland: a text field inside one can be
// clicked but not typed into, and this panel is a text field and little else.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.nag"
  ipcTarget: "jankeesvw.nag"

  // Panel's own IpcHandler is switched off so this file can add `refresh` to
  // the same target; two handlers on one target is one too many, so the five it
  // would have given us are repeated below. That method is what lets an alarm
  // set from the menu or the command line reach the bar at once, instead of
  // waiting out the poll while the countdown shows the wrong number.
  manageIpc: false

  // The script sits next to this file, so the plugin runs from wherever it was
  // installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/nag").toString().replace(/^file:\/\//, "")

  // nf-md-timer, U+F051F. Deliberately not a bell: the shell already spends
  // that glyph on notifications and on its own reminders, and two bells in one
  // bar is a bar you have to read twice. Past U+FFFF, so it is written as the
  // surrogate pair rather than as a five-digit escape, which \u would silently
  // truncate into a different glyph with a stray character after it.
  readonly property string iconTimer: "\uDB81\uDD1F"
  readonly property string iconClose: "\uF00D"
  readonly property string iconSnooze: "\uF186"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // [{ id, at, message, atLabel, remaining, remainingSeconds, ringing }]
  property var alarms: []
  property int ringingCount: 0
  property var nextAlarm: null

  // Seconds since the epoch, ticked locally. The countdown in the bar has to
  // move every second, and running a process every second to find that out
  // would be absurd for a number we can work out from the timestamps we
  // already have.
  property int nowSeconds: Math.floor(Date.now() / 1000)

  property string draft: ""
  property var preview: null
  property string actionError: ""

  // One cursor over the list, with -1 meaning "nowhere, keep typing". The text
  // field keeps the focus the whole time, because typing is what this panel is
  // for and a cursor that steals it would make the arrow keys and the letters
  // fight over the same keyboard. Down walks into the list, typing walks back
  // out of it.
  property int cursor: -1

  // The field accepts far more than the one shape a single placeholder can
  // show, and none of it is guessable: nobody tries "wed 18:15" at a box that
  // only ever said "15:15". So the placeholder is a different one on every
  // open, which teaches the range without anything moving on screen.
  readonly property var examples: [
    "15:15 pick up the kids",
    "5m tea",
    "tomorrow 9:00 dentist",
    "wed 18:15 hockey",
    "1h30 call Paul",
    "2d water the plants"
  ]
  property int exampleIndex: 0

  function moveCursor(step) {
    if (alarms.length === 0) { cursor = -1; return }
    var next = cursor + step
    if (next < -1) next = -1
    if (next >= alarms.length) next = alarms.length - 1
    cursor = next
  }

  function cursorAlarm() {
    if (cursor < 0 || cursor >= alarms.length) return null
    return alarms[cursor]
  }

  // The list is rebuilt on every refresh, so an index that pointed at the last
  // row has to be brought back in range or the cursor lands on nothing.
  onAlarmsChanged: if (cursor >= alarms.length) cursor = alarms.length - 1

  // --- formatting ----------------------------------------------------------

  // Deliberately the same shapes bin/nag prints, because both end up on screen
  // together: the panel's list is rendered here and a notification body comes
  // from the script.
  function formatRemaining(seconds) {
    if (seconds < 0) seconds = 0
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor((seconds % 86400) / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    var secs = seconds % 60

    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m"
    if (minutes > 0) return minutes + "m"
    return secs + "s"
  }

  function remainingFor(alarm) {
    if (!alarm) return ""
    if (alarm.ringing) return "now"
    return formatRemaining(Number(alarm.at) - root.nowSeconds)
  }

  // Everything that reaches a Text element here is PlainText, but the shared
  // bar tooltip is the shell's own component and its textFormat is not ours to
  // set, so the angle brackets come out before a message gets there.
  function plain(value) {
    return String(value || "")
      // Markup characters first: the bar tooltip, the notification body and
      // the shell's own components render with AutoText and this plugin
      // cannot pin their format. Then C0/C1 and the bidi overrides, which can
      // reorder a label into saying something it does not say.
      .replace(/[<>&]/g, " ")
      .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .slice(0, 200)
  }

  function labelFor(alarm) {
    var message = plain(alarm && alarm.message ? alarm.message : "")
    return message.length > 0 ? message : "Alarm"
  }

  // What the bar says on hover: "Tea at 11:25", "Dentist tomorrow at 09:00".
  // A message is typed in the middle of a sentence and arrives lowercase, so it
  // gets the capital here rather than being stored with one.
  function sentenceFor(alarm) {
    if (!alarm) return "No alarms"
    var label = labelFor(alarm)
    label = label.charAt(0).toUpperCase() + label.slice(1)
    if (alarm.ringing) return label + " now"
    return label + " " + plain(alarm.atPhrase || "")
  }

  // --- the bar -------------------------------------------------------------

  // The last five minutes go red. That is the window where the countdown stops
  // being information and starts being something to act on: it is the point
  // where you still have time to put your shoes on, and the point after which
  // you no longer do.
  readonly property int soonSeconds: 300

  function isSoon(alarm) {
    if (!alarm) return false
    if (alarm.ringing) return true
    return (Number(alarm.at) - root.nowSeconds) <= root.soonSeconds
  }

  readonly property bool nextIsSoon: ringingCount > 0 || isSoon(nextAlarm)

  readonly property string barLabel: {
    if (ringingCount > 0) return "now"
    if (!nextAlarm) return ""
    return remainingFor(nextAlarm)
  }

  TextMetrics {
    id: barMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: root.barLabel
  }

  // Panel is a bare Item, so it has no size of its own and the bar would give
  // the widget zero width. Set it here from the metrics, never from a child
  // that fills this item: that is a loop where nothing decides the size and
  // everything collapses to zero, which still draws but cannot be clicked.
  readonly property int barSlot:
    Style.bar.iconFont
    + (barLabel !== "" ? Math.ceil(barMetrics.width) + Style.space(5) : 0)
    + Style.space(14)

  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // --- talking to the script -----------------------------------------------

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function applyList(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { return }
    if (!data || data.ok !== true) return

    alarms = data.alarms || []
    ringingCount = Number(data.ringingCount || 0)
    nextAlarm = data.next || null

    // Wake up exactly when the next alarm is due rather than polling for it.
    // The poll below is only a safety net for alarms set from the CLI.
    fireTimer.stop()
    if (nextAlarm) {
      var wait = (Number(nextAlarm.at) - Math.floor(Date.now() / 1000)) * 1000 + 1500
      if (wait > 0 && wait < 2147483) {
        fireTimer.interval = wait
        fireTimer.start()
      }
    }
  }

  function runAction(args) {
    if (actionProc.running) return
    actionError = ""
    actionProc.command = [root.script].concat(args)
    actionProc.running = true
  }

  function setAlarm() {
    var text = draft.trim()
    if (text.length === 0) return
    if (!preview || preview.ok !== true) return
    runAction(["set", text])
    draft = ""
    preview = null
  }

  function cancelAlarm(id) { runAction(["cancel", String(id)]) }
  function dismissAlarm(id) { runAction(["dismiss", String(id)]) }
  function snoozeAlarm(id, minutes) { runAction(["snooze", String(id), String(minutes)]) }

  function requestPreview() {
    if (draft.trim().length === 0) { preview = null; return }
    previewDebounce.restart()
  }

  // The three helpers below all read the script's stdout the same way, and
  // deliberately not with StdioCollector: that retains the whole stream before
  // any length check of ours can run, inside the one process that hosts every
  // widget on the desktop. SplitParser with an empty marker hands over raw
  // chunks instead, so the budget is enforced while the bytes arrive.
  //
  // bin/nag already bounds what it prints, but a cap that lives only in the
  // producer is a cap that disappears the day something replaces the producer.
  readonly property int maxBytes: 131072

  // Deadline, then TERM, then KILL. setsid in the script is not needed here
  // because the helper is a single bash process with no children of its own
  // that outlive it, but the escalation timer still has to exist: a helper that
  // never exits would otherwise hold its Process object forever.
  readonly property int deadlineMs: 15000

  property string listBuf: ""
  property string parseBuf: ""
  property string actionBuf: ""

  // Returns the buffer with the chunk appended, or a null when the budget is
  // gone, in which case the caller stops the process and keeps nothing.
  function appendBounded(buffer, chunk) {
    var next = buffer + chunk
    return next.length > root.maxBytes ? null : next
  }

  Process {
    id: listProc
    command: [root.script, "list"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        var next = root.appendBounded(root.listBuf, chunk)
        if (next === null) { root.listBuf = ""; listProc.signal(15); listKill.start(); return }
        root.listBuf = next
      }
    }
    onRunningChanged: if (running) listDeadline.restart(); else { listDeadline.stop(); listKill.stop() }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyList(root.listBuf)
      root.listBuf = ""
    }
  }
  Timer { id: listDeadline; interval: root.deadlineMs; onTriggered: { listProc.signal(15); listKill.start() } }
  Timer { id: listKill; interval: 2000; onTriggered: listProc.signal(9) }

  Process {
    id: parseProc
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        var next = root.appendBounded(root.parseBuf, chunk)
        if (next === null) { root.parseBuf = ""; parseProc.signal(15); parseKill.start(); return }
        root.parseBuf = next
      }
    }
    onRunningChanged: if (running) parseDeadline.restart(); else { parseDeadline.stop(); parseKill.stop() }
    onExited: function(exitCode) {
      var data = null
      if (exitCode === 0) {
        try { data = JSON.parse(root.parseBuf) } catch (e) { data = null }
      }
      root.preview = data
      root.parseBuf = ""
    }
  }
  Timer { id: parseDeadline; interval: root.deadlineMs; onTriggered: { parseProc.signal(15); parseKill.start() } }
  Timer { id: parseKill; interval: 2000; onTriggered: parseProc.signal(9) }

  Process {
    id: actionProc
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        var next = root.appendBounded(root.actionBuf, chunk)
        if (next === null) { root.actionBuf = ""; actionProc.signal(15); actionKill.start(); return }
        root.actionBuf = next
      }
    }
    onRunningChanged: if (running) actionDeadline.restart(); else { actionDeadline.stop(); actionKill.stop() }
    onExited: function(exitCode) {
      var data = null
      try { data = JSON.parse(root.actionBuf) } catch (e) { data = null }
      if (exitCode !== 0) root.actionError = "that did not work"
      else if (data && data.ok === false) root.actionError = root.plain(data.error || "that did not work")
      root.actionBuf = ""
      root.refresh()
    }
  }
  Timer { id: actionDeadline; interval: root.deadlineMs; onTriggered: { actionProc.signal(15); actionKill.start() } }
  Timer { id: actionKill; interval: 2000; onTriggered: actionProc.signal(9) }

  // Nothing of ours should outlive the widget being torn down.
  Component.onDestruction: {
    listProc.signal(15)
    parseProc.signal(15)
    actionProc.signal(15)
  }

  // --- timers --------------------------------------------------------------

  // Only the displayed countdown, no process. Idle when there is nothing to
  // count down to.
  Timer {
    interval: 1000
    repeat: true
    running: root.alarms.length > 0
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  Timer {
    id: fireTimer
    repeat: false
    onTriggered: root.refresh()
  }

  // Catches alarms set from somewhere else, which for this plugin means the
  // command line.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: previewDebounce
    interval: 180
    repeat: false
    onTriggered: {
      if (parseProc.running) { previewDebounce.restart(); return }
      parseProc.command = [root.script, "parse", root.draft]
      parseProc.running = true
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Parameterless, and it only re-reads what the widget already re-reads on
    // its own timer. There is nothing here that changes state, deletes
    // anything, or hands back something private.
    function refresh(): void { root.refresh() }
  }

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (!opened) return
    refresh()
    // A new example every time the panel opens, rather than on a timer. Over a
    // week you see all of them, and the line never moves while you are reading
    // it, which is what a rotating placeholder does wrong.
    exampleIndex = (exampleIndex + 1) % examples.length
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.barSlot
    tooltipText: {
      if (root.alarms.length === 0) return "No alarms"
      var alarm = root.ringingCount > 0 ? root.alarms[0] : root.nextAlarm
      if (!alarm) return "No alarms"
      return root.sentenceFor(alarm)
    }
    onPressed: function(b) { root.toggle() }

    // The countdown belongs in the bar and not only in the panel: the whole
    // reason to set one of these is that you are looking at something else.
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.iconTimer
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.nextIsSoon
              ? root.urgent
              : (root.opened || root.nextAlarm ? root.accent : root.foreground)

            // A ringing alarm has to be visible from across the room, and it
            // keeps pulsing until it is answered. That is the whole product.
            SequentialAnimation on opacity {
              running: root.ringingCount > 0
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.barLabel !== ""
            textFormat: Text.PlainText
            text: root.barLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
            color: root.nextIsSoon ? root.urgent : root.foreground
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The panel opens ready to type, which is the only interaction it has.
    focusTarget: inputField

    // Plain property reads rather than fittedContentWidth, which is evaluated
    // once on open and would not follow a panel that grows as alarms are added.
    readonly property int desiredWidth: Style.space(300)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    // A plain Item rather than PanelKeyCatcher. That component reads keys
    // before its descendants and turns Tab, Enter and Space into signals of its
    // own, which is right for a panel that is a list of rows and wrong for one
    // that is a form: every button here would be reachable with Tab and none of
    // them pressable, because the catcher ate the Enter first.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        // --- the field ------------------------------------------------------

        Text {
          textFormat: Text.PlainText
          text: "New alarm"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.foreground, 1.5)
        }

        TextField {
          id: inputField
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: root.examples[root.exampleIndex]
          text: root.draft
          // The shared TextField does not opt into the Tab ring on its own, so
          // without this you can tab out of the field and never tab back in.
          activeFocusOnTab: true

          onTextChanged: {
            if (text !== root.draft) {
              root.draft = text
              // Typing is a statement about the field, not about the list, so
              // it takes the cursor back out of the rows.
              root.cursor = -1
              root.requestPreview()
            }
          }

          // The field holds the focus for the whole life of the panel, so this
          // is where the panel's keys live. Up and Down do nothing in a
          // single-line field, which is what leaves them free to drive the list.
          Keys.onPressed: function(event) {
            var onRow = root.cursor >= 0

            switch (event.key) {
            case Qt.Key_Down:
              root.moveCursor(1)
              event.accepted = true
              return

            case Qt.Key_Up:
              root.moveCursor(-1)
              event.accepted = true
              return

            case Qt.Key_Return:
            case Qt.Key_Enter:
              // On a ringing row Enter is snooze, which is the only thing worth
              // one key when an alarm is going off in front of you.
              if (onRow) {
                var alarm = root.cursorAlarm()
                if (alarm && alarm.ringing) root.snoozeAlarm(alarm.id, 5)
              } else {
                root.setAlarm()
              }
              event.accepted = true
              return

            case Qt.Key_Delete:
              if (onRow) {
                var target = root.cursorAlarm()
                if (target) {
                  if (target.ringing) root.dismissAlarm(target.id)
                  else root.cancelAlarm(target.id)
                }
                event.accepted = true
              }
              return

            case Qt.Key_Escape:
              // Escape steps back out of the list first and closes the panel
              // second, so it never throws away a half-typed alarm by surprise.
              if (onRow) {
                root.cursor = -1
                event.accepted = true
              }
              return
            }
          }
        }

        // Reads back what the script made of it, live, so a time that will not
        // parse is visible before Enter rather than after.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: {
            if (root.actionError !== "") return root.urgent
            if (root.draft.trim().length === 0) return Qt.darker(root.foreground, 1.6)
            if (!root.preview) return Qt.darker(root.foreground, 1.6)
            return root.preview.ok === true ? root.accent : Qt.darker(root.foreground, 1.6)
          }
          // The same sentence the bar gives on hover, so what you are about to
          // get is spelled out in the words you will see afterwards: it reads
          // back both halves of the split, which is the only way to notice that
          // "wed 18:15 hockey" put the Wednesday in the time and not in the
          // message.
          // Nothing recognised means nothing to say. The line still occupies
          // its row, though: a line that appears and disappears would move the
          // whole list up and down on the keystroke that makes a time valid.
          text: {
            if (root.actionError !== "") return root.actionError
            if (!root.preview || root.preview.ok !== true) return " "

            return root.sentenceFor(root.preview)
              + ", in " + root.plain(root.preview.remaining)
          }
        }


        // --- the list -------------------------------------------------------

        PanelSeparator {
          width: parent.width
          visible: root.alarms.length > 0
        }

        Flickable {
          width: parent.width
          height: Math.min(alarmColumn.implicitHeight, Style.space(360))
          visible: root.alarms.length > 0
          clip: true
          contentWidth: width
          contentHeight: alarmColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: alarmColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.alarms

              delegate: Rectangle {
                required property var modelData
                required property int index

                readonly property bool hasCursor: root.cursor === index
                readonly property bool soon: root.isSoon(modelData)
                readonly property color rowColor: soon ? root.urgent : root.foreground

                width: alarmColumn.width
                height: Math.max(Style.space(30), rowText.implicitHeight + Style.space(10))
                radius: Style.cornerRadius
                color: {
                  if (modelData.ringing) return Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
                  if (hasCursor) return Style.hoverFill
                  return "transparent"
                }

                Row {
                  id: rowText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.right: rowActions.left
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.plain(modelData.atLabel)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                    color: rowColor
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.remainingFor(modelData)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                    color: soon ? root.urgent : Qt.darker(root.foreground, 1.6)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, rowText.width - x)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: root.labelFor(modelData)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                    color: rowColor
                  }
                }

                // Declared left to right, because Tab follows the order the
                // children are written in and a ring that walks backwards is
                // one you have to look at to use.
                Row {
                  id: rowActions
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: modelData.ringing
                    focusable: false
                    iconText: root.iconSnooze
                    tooltipText: "Snooze 5 minutes"
                    foreground: rowColor
                    fontFamily: root.fontFamily
                    onClicked: root.snoozeAlarm(modelData.id, 5)
                  }

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    focusable: false
                    iconText: root.iconClose
                    tooltipText: modelData.ringing ? "Dismiss" : "Remove"
                    foreground: rowColor
                    fontFamily: root.fontFamily
                    onClicked: {
                      if (modelData.ringing) root.dismissAlarm(modelData.id)
                      else root.cancelAlarm(modelData.id)
                    }
                  }
                }
              }
            }
          }
        }

      }
    }
  }
}
