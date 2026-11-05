import Cocoa
import CoreMIDI
import Darwin

// MIDIReceived delivers input from a virtual source. Unlike MIDISend, timestamp
// zero does not mean "now" here; every generated packet needs valid host time.
func withSourcePacket(_ bytes: [UInt8], _ deliver: (UnsafePointer<MIDIPacketList>) -> OSStatus) -> OSStatus {
 guard !bytes.isEmpty, bytes.count <= 256 else { return OSStatus(-50) }
 var list = MIDIPacketList()
 return withUnsafeMutablePointer(to: &list) { pointer in
  let packet = MIDIPacketListInit(pointer)
  return bytes.withUnsafeBufferPointer { buffer in
   _ = MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size, packet,
                        mach_absolute_time(), buffer.count, buffer.baseAddress!)
   return deliver(UnsafePointer(pointer))
  }
 }
}

let commands: [(Int, String)] = [
 (1,"Stop"),(2,"Play"),(3,"Deferred Play"),(4,"Fast Forward"),(5,"Rewind"),
 (6,"Record Strobe"),(7,"Record Exit"),(8,"Record Pause"),(9,"Pause"),
 (10,"Eject"),(11,"Chase"),(12,"Command Error Reset"),(13,"MMC Reset"),
 (250,"Realtime Start"),(251,"Realtime Continue"),(252,"Realtime Stop")]
func defaultNote(_ command: Int) -> Int { command == 2 ? 94 : command == 1 ? 95 : command == 3 ? 96 : 96 + (commands.firstIndex { $0.0 == command } ?? 0) }

enum OutputMode: Int { case mcu = 0, custom = 1, monitor = 2 }
func mcuNote(_ command: Int) -> Int? {
 switch command {
 case 1, 252: return 93
 case 2, 3, 250, 251: return 94
 case 4: return 92
 case 5: return 91
 case 6: return 95
 default: return nil
 }
}
struct NotePulse: Equatable {
 let press: [UInt8]
 let release: [UInt8]
 var key: Int { Int(press[0] & 0x0F) * 128 + Int(press[1]) }
}
func makePulse(command: Int, mode: OutputMode, customNote: Int?, channel: Int) -> NotePulse? {
 if mode == .monitor { return nil }
 if mode == .mcu {
  guard let n = mcuNote(command) else { return nil }
  return NotePulse(press: [0x90, UInt8(n), 127], release: [0x90, UInt8(n), 0])
 }
 guard let n = customNote, (0...127).contains(n), (0...15).contains(channel) else { return nil }
 return NotePulse(press: [UInt8(0x90 + channel), UInt8(n), 100],
                  release: [UInt8(0x80 + channel), UInt8(n), 0])
}

// Separate host return path: never translate Reason's LED feedback as button presses.
struct SysExStream {
 var buffer: [UInt8] = []
 mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
  var messages: [[UInt8]] = []
  for b in bytes {
   if b >= 0xF8 { continue }
   if b == 0xF0 { buffer = [b] }
   else if b == 0xF7 {
    if !buffer.isEmpty { buffer.append(b); messages.append(buffer) }
    buffer = []
   } else if b >= 0x80 { buffer = [] }
   else if !buffer.isEmpty {
    if buffer.count < 1024 { buffer.append(b) } else { buffer = [] }
   }
  }
  return messages
 }
}
struct MCUHandshake {
 let header: [UInt8] = [0xF0, 0, 0, 0x66, 0x14]
 let serial = Array("MP10BRG".utf8)
 let challenge: [UInt8] = [1, 2, 3, 4]
 var awaitingReply = false
 static func response(_ c: [UInt8]) -> [UInt8] {
  precondition(c.count == 4)
  let v = c.map(Int.init)
  return [v[0] + (v[1] ^ 0x0A) - v[3],
          (v[2] >> 4) ^ (v[0] + v[3]),
          (v[3] - (v[2] << 2)) ^ (v[0] | v[1]),
          v[1] - v[2] + (0xF0 ^ (v[3] << 4))].map { UInt8($0 & 0x7F) }
 }
 mutating func reply(to message: [UInt8]) -> [UInt8]? {
  guard message.starts(with: header), message.last == 0xF7, message.count >= 7 else { return nil }
  let command = message[5]
  if (command == 0x00 || command == 0x63) && message.count == 7 {
   awaitingReply = true
   return header + [1] + serial + challenge + [0xF7]
  }
  if command == 0x02 && message.count == 18 && awaitingReply {
   guard Array(message[6..<13]) == serial else { return nil }
   awaitingReply = false
   let valid = Array(message[13..<17]) == Self.response(challenge)
   return header + [valid ? 3 : 4] + serial + [0xF7]
  }
  if command == 0x13 && message == header + [0x13, 0, 0xF7] {
   return header + [0x14] + Array("V1.5 ".utf8) + [0xF7]
  }
  if message == header + [0x0F, 0x7F, 0xF7] { awaitingReply = false }
  return nil
 }
}
func packetBytes(_ list: UnsafePointer<MIDIPacketList>) -> [UInt8] {
 var bytes: [UInt8] = []
 var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
 for _ in 0..<list.pointee.numPackets {
  let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
  bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(packet.pointee.length)))
  packet = UnsafePointer(MIDIPacketNext(packet))
 }
 return bytes
}

// Stream parser: SysEx may span packets; MIDI realtime bytes may occur inside it.
struct Parser {
 var sysex: [UInt8] = []
 mutating func feed(_ bytes: [UInt8]) -> [(Int, [UInt8])] {
  var events: [(Int,[UInt8])] = []
  for b in bytes {
   if b >= 0xF8 {
    if [0xFA,0xFB,0xFC].contains(b) { events.append((Int(b),[b])) }
    continue
   }
   if b == 0xF0 { sysex = [b]; continue }
   if b == 0xF7 {
    if !sysex.isEmpty {
     sysex.append(b)
     if sysex.count == 6 && sysex[1] == 0x7F && sysex[3] == 0x06 && (1...13).contains(sysex[4]) {
      events.append((Int(sysex[4]),sysex))
     }
    }
    sysex = []; continue
   }
   if b >= 0x80 { sysex = []; continue }
   if !sysex.isEmpty {
    if sysex.count < 1024 { sysex.append(b) } else { sysex = [] }
   }
  }
  return events
 }
}
func check(_ status: OSStatus, _ action: String) throws {
 if status != noErr { throw NSError(domain: "CoreMIDI", code: Int(status), userInfo: [NSLocalizedDescriptionKey:"\(action): CoreMIDI error \(status)"]) }
}

struct RememberedInput: Codable, Equatable {
 let uniqueID: Int32?
 let name: String
 let manufacturer: String?
 let model: String?
}
struct InputSource {
 let endpoint: MIDIEndpointRef
 let identity: RememberedInput
}
enum InputChoice: Equatable { case connect(MIDIEndpointRef), missing, ambiguous, disabled }
func chooseInput(_ sources:[InputSource], remembered:RememberedInput?, disabled:Bool) -> InputChoice {
 if disabled { return .disabled }
 if let remembered=remembered {
  if let id=remembered.uniqueID {
   let exact=sources.filter { $0.identity.uniqueID == id }
   if exact.count == 1 { return .connect(exact[0].endpoint) }
   if exact.count > 1 { return .ambiguous }
  }
  // Some USB drivers assign a new ID after replugging. Fall back only to a
  // single matching name and all available saved manufacturer/model metadata.
  let matches=sources.filter {
   $0.identity.name == remembered.name &&
   (remembered.manufacturer == nil || $0.identity.manufacturer == remembered.manufacturer) &&
   (remembered.model == nil || $0.identity.model == remembered.model)
  }
  if matches.count == 1 { return .connect(matches[0].endpoint) }
  return matches.isEmpty ? .missing : .ambiguous
 }
 let mp10=sources.filter { $0.identity.name.localizedCaseInsensitiveContains("MP10") }
 if mp10.count == 1 { return .connect(mp10[0].endpoint) }
 return mp10.isEmpty ? .missing : .ambiguous
}

final class Bridge: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
 var window: NSWindow!
 var statusItem: NSStatusItem?
 let menuConnection = NSMenuItem(title:"Starting MIDI…",action:nil,keyEquivalent:"")
 let menuMode = NSMenuItem(title:"",action:nil,keyEquivalent:"")
 var menuHide: NSMenuItem?
 let input = NSPopUpButton()
 let channel = NSPopUpButton()
 let modeSelector = NSPopUpButton()
 let modeHint = NSTextField(labelWithString: "")
 let pulseHint = NSTextField(labelWithString: "")
 var mode: OutputMode { OutputMode(rawValue: modeSelector.indexOfSelectedItem) ?? .mcu }
 var testButtons: [Int:NSButton] = [:]
 let rawLog = NSButton(checkboxWithTitle:"Raw MIDI log",target:nil,action:nil)
 let log = NSTextView()
 let status = NSTextField(labelWithString: "")
 var fields: [Int:NSTextField] = [:]
 var sources: [MIDIEndpointRef] = []
 var selected: MIDIEndpointRef = 0
 var connectionGeneration: UInt = 0
 var refreshWork: DispatchWorkItem?
 var reconnectTimer: Timer?
 var rememberedInput: RememberedInput? {
  guard let data=defaults.data(forKey:"rememberedInput") else { return nil }
  return try? JSONDecoder().decode(RememberedInput.self,from:data)
 }
 var client = MIDIClientRef(), port = MIDIPortRef(), output = MIDIEndpointRef(), feedback = MIDIEndpointRef()
 var hostParser = SysExStream()
 var handshake = MCUHandshake()
 var parser = Parser()
 var logLines: [String] = []
 var defaults = UserDefaults.standard
 var activeReleases: [Int:[UInt8]] = [:]
 var enabled = false

 func applicationDidFinishLaunching(_ notification: Notification) {
  buildUI()
  setUpMenuBar()
  do {
   try check(MIDIClientCreateWithBlock("MP10 Reason Bridge" as CFString, &client) { [weak self] notification in
    let id = notification.pointee.messageID
    if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgPropertyChanged {
     let removed = id == .msgObjectRemoved
      ? UnsafeRawPointer(notification).assumingMemoryBound(to:MIDIObjectAddRemoveNotification.self).pointee.child
      : 0
     DispatchQueue.main.async {
      guard let self=self else { return }
      if removed != 0 && removed == self.selected { self.disconnectInput() }
      self.scheduleRefresh()
     }
    }
   }, "Create MIDI client")
   try check(MIDISourceCreate(client,"MP10 Reason Bridge" as CFString,&output),"Create virtual output")
   try restoreVirtualIdentity(output,key:"virtualOutputID")
   try check(MIDIInputPortCreateWithBlock(client,"MP10 Input" as CFString,&port) { [weak self] list, ref in
    let bytes = packetBytes(list)
    let generation = ref.map { UInt(bitPattern:$0) } ?? 0
    DispatchQueue.main.async {
     guard let self=self,self.connectionGeneration == generation else { return }
     self.receive(bytes)
    }
   },"Create MIDI input")
   try check(MIDIDestinationCreateWithBlock(client,"MP10 Reason Bridge Feedback" as CFString,&feedback) { [weak self] list, _ in
    let bytes = packetBytes(list)
    DispatchQueue.main.async { self?.receiveHost(bytes) }
   }, "Create virtual feedback input")
   try restoreVirtualIdentity(feedback,key:"virtualFeedbackID")
   enabled = true
   refresh(nil)
   reconnectTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
    guard let self=self,self.selected == 0,!self.defaults.bool(forKey:"inputAutoConnectDisabled") else { return }
    self.refresh(nil)
   }
   append("Ready. Output: MP10 Reason Bridge. Only transport commands are translated.")
  } catch { status.stringValue = error.localizedDescription; append(error.localizedDescription) }
  showWindow(nil)
 }
 func buildUI() {
  window = NSWindow(contentRect:NSRect(x:0,y:0,width:710,height:840),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  window.title = "MP10 → Reason Bridge · 1.5"
  window.delegate=self
  window.isReleasedWhenClosed=false
  if let button=window.standardWindowButton(.miniaturizeButton) {
   button.target=self;button.action=#selector(hideWindow(_:))
  }
  window.center()
  let view = window.contentView!
  func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat) {
   let l = NSTextField(labelWithString:text); l.frame = NSRect(x:x,y:y,width:w,height:22); view.addSubview(l)
  }
  label("MP10 → Reason",20,802,400)
  label("MIDI Input",20,763,110)
  input.frame = NSRect(x:135,y:759,width:410,height:28); input.target=self; input.action=#selector(selectInput); view.addSubview(input)
  let refresh = NSButton(title:"Refresh",target:self,action:#selector(refresh(_:))); refresh.frame=NSRect(x:550,y:759,width:140,height:28);view.addSubview(refresh)
  label("Reason MIDI In: MP10 Reason Bridge",20,726,670)
  label("Reason MIDI Out: MP10 Reason Bridge Feedback",20,704,670)
  label("Output mode",20,676,130)
  modeSelector.frame=NSRect(x:150,y:672,width:285,height:28)
  modeSelector.addItems(withTitles:["Mackie Control (MCU)","Custom MIDI notes","Monitor input only"])
  modeSelector.selectItem(at:OutputMode(rawValue:defaults.integer(forKey:"outputMode"))?.rawValue ?? 0)
  modeSelector.target=self;modeSelector.action=#selector(changeMode);view.addSubview(modeSelector)
  label("MIDI channel",450,676,100)
  channel.frame=NSRect(x:550,y:672,width:130,height:28);channel.addItems(withTitles:(1...16).map(String.init));channel.selectItem(at:max(0,min(15,defaults.integer(forKey:"channel"))));channel.target=self;channel.action=#selector(saveChannel);view.addSubview(channel)
  label("Command",20,644,300);label("Note number (0–127)",350,644,210)
  label("Test",600,644,75)
  for (index,item) in commands.enumerated() {
   let y = CGFloat(615-index*26)
   label(String(format:"%@  ·  %02X",item.1,item.0),20,y,330)
   let field=NSTextField(frame:NSRect(x:350,y:y,width:100,height:23))
   let key="note.\(item.0)"
   field.integerValue=defaults.object(forKey:key) == nil ? defaultNote(item.0) : defaults.integer(forKey:key)
   field.tag=item.0;field.target=self;field.action=#selector(saveNote(_:));view.addSubview(field);fields[item.0]=field
   let button=NSButton(title:"Send",target:self,action:#selector(testNote(_:)));button.tag=item.0;button.frame=NSRect(x:590,y:y-1,width:90,height:25);view.addSubview(button);testButtons[item.0]=button
  }
  modeHint.frame=NSRect(x:20,y:183,width:670,height:22);view.addSubview(modeHint)
  pulseHint.frame=NSRect(x:20,y:160,width:670,height:22);view.addSubview(pulseHint)
  updateModeUI()
  status.frame=NSRect(x:20,y:133,width:670,height:22);view.addSubview(status)
  rawLog.frame=NSRect(x:20,y:104,width:180,height:24);view.addSubview(rawLog)
  let copy=NSButton(title:"Copy Log",target:self,action:#selector(copyLog));copy.frame=NSRect(x:580,y:104,width:110,height:25);view.addSubview(copy)
  let clear=NSButton(title:"Clear Log",target:self,action:#selector(clearLog));clear.frame=NSRect(x:460,y:104,width:110,height:25);view.addSubview(clear)
  let scroll=NSScrollView(frame:NSRect(x:20,y:20,width:670,height:80));scroll.hasVerticalScroller=true
  log.frame=scroll.bounds;log.isVerticallyResizable=true;log.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
  log.isEditable=false;log.isSelectable=true;log.font=NSFont.monospacedSystemFont(ofSize:11,weight:.regular)
  log.autoresizingMask=[.width];log.textContainer?.widthTracksTextView=true
  scroll.documentView=log;view.addSubview(scroll)
  let menu=NSMenu();let item=NSMenuItem();menu.addItem(item);let appMenu=NSMenu()
  let show=appMenu.addItem(withTitle:"Show Window",action:#selector(showWindow(_:)),keyEquivalent:"0");show.target=self
  let hide=appMenu.addItem(withTitle:"Hide to Menu Bar",action:#selector(hideWindow(_:)),keyEquivalent:"w");hide.target=self
  appMenu.addItem(.separator())
  let quit=appMenu.addItem(withTitle:"Quit MP10 Reason Bridge",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");quit.target=NSApp
  item.submenu=appMenu;NSApp.mainMenu=menu
  let windowItem=NSMenuItem(title:"Window",action:nil,keyEquivalent:"");menu.addItem(windowItem)
  let windowMenu=NSMenu(title:"Window")
  let minimize=windowMenu.addItem(withTitle:"Hide to Menu Bar",action:#selector(hideWindow(_:)),keyEquivalent:"m");minimize.target=self
  windowItem.submenu=windowMenu

 }
 func setUpMenuBar() {
  let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
  statusItem=item
  let image=Bundle.main.url(forResource:"MenuBarIcon",withExtension:"pdf").flatMap { NSImage(contentsOf:$0) }
   ?? NSImage(systemSymbolName:"play.circle",accessibilityDescription:"MP10 Reason Bridge")
  image?.size=NSSize(width:18,height:18);image?.isTemplate=true
  item.button?.image=image
  item.button?.setAccessibilityLabel("MP10 Reason Bridge")
  let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false
  menuConnection.isEnabled=false;menuMode.isEnabled=false
  menu.addItem(menuConnection);menu.addItem(menuMode);menu.addItem(.separator())
  let show=menu.addItem(withTitle:"Show Window",action:#selector(showWindow(_:)),keyEquivalent:"");show.target=self
  let hide=menu.addItem(withTitle:"Hide Window",action:#selector(hideWindow(_:)),keyEquivalent:"");hide.target=self;menuHide=hide
  let refresh=menu.addItem(withTitle:"Refresh MIDI Inputs",action:#selector(refresh(_:)),keyEquivalent:"");refresh.target=self
  menu.addItem(.separator())
  let quit=menu.addItem(withTitle:"Quit MP10 Reason Bridge",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"");quit.target=NSApp
  item.menu=menu
  updateStatusMenu()
 }
 func updateStatusMenu() {
  let connection=status.stringValue.isEmpty ? "Starting MIDI…" : status.stringValue
  menuConnection.title=connection.count > 70 ? String(connection.prefix(67))+"…" : connection
  menuConnection.toolTip=connection
  menuMode.title="Mode: \(modeSelector.titleOfSelectedItem ?? "Mackie Control (MCU)")"
  menuHide?.isEnabled=window?.isVisible ?? false
  statusItem?.button?.toolTip="MP10 Reason Bridge\n\(connection)\n\(menuMode.title)"
 }
 func menuWillOpen(_ menu:NSMenu) { updateStatusMenu() }
 @objc func showWindow(_ sender:Any?) {
  NSApp.setActivationPolicy(.regular)
  if window.isMiniaturized { window.deminiaturize(sender) }
  window.makeKeyAndOrderFront(sender)
  NSApp.activate(ignoringOtherApps:true)
  updateStatusMenu()
 }
 @objc func hideWindow(_ sender:Any?) {
  window.makeFirstResponder(nil)
  window.orderOut(sender)
  NSApp.setActivationPolicy(.accessory)
  updateStatusMenu()
 }
 func windowShouldClose(_ sender:NSWindow) -> Bool {
  hideWindow(sender)
  return false
 }
 func windowDidMiniaturize(_ notification:Notification) { hideWindow(nil) }
 func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
  showWindow(nil)
  return true
 }
 func saveCustomNotes() {
  guard mode == .custom else { return }
  for command in commands { _ = note(command.0) }
 }
 @objc func changeMode() {
  // Fields still contain the previous mode's values when the selector changes.
  if defaults.integer(forKey:"outputMode") == 1 {
   for command in commands { _ = note(command.0) }
  }
  releaseAll()
  defaults.set(mode.rawValue,forKey:"outputMode")
  hostParser=SysExStream();handshake=MCUHandshake()
  updateModeUI()
  updateStatusMenu()
  if mode == .monitor { append("MONITOR ONLY: hardware input is recorded; no MIDI is sent to Reason. Keep the UFX connected directly to Reason.") }
  else { append(mode == .mcu ? "MCU: Channel 1, velocity 127/0. Select Mackie > Control in Reason." : "Custom MIDI note mapping enabled.") }
 }
 func updateModeUI() {
  rawLog.isEnabled = mode != .monitor
  if mode == .monitor { rawLog.state = .on }
  channel.isEnabled = mode == .custom
  channel.selectItem(at:mode == .mcu ? 0 : max(0,min(15,defaults.integer(forKey:"channel"))))
  for (command,field) in fields {
   field.isEditable = mode == .custom
   field.isSelectable = mode == .custom
   if mode == .monitor { field.stringValue = "—" }
   else if mode == .mcu { field.stringValue = mcuNote(command).map(String.init) ?? "—" }
   else {
    let key="note.\(command)"
    field.integerValue=defaults.object(forKey:key) == nil ? defaultNote(command) : defaults.integer(forKey:key)
   }
   testButtons[command]?.isEnabled = mode == .custom || (mode == .mcu && mcuNote(command) != nil)
  }
  modeHint.stringValue = mode == .mcu ? "MCU: Rewind 91 · Fast Forward 92 · Stop 93 · Play 94 · Record 95" : "Custom notes: your existing assignments are preserved."
  if mode == .monitor { modeHint.stringValue = "Select the UFX input, press its transport buttons, then copy the log." }
  pulseHint.stringValue = mode == .mcu ? "Channel 1 · Note On 127 → Note On 0 after 80 ms · — means unassigned." : "Note On 100 → Note Off 0 after 80 ms · Select any MIDI channel."
  if mode == .monitor { pulseHint.stringValue = "Monitor only: no MIDI output. Reason stays connected directly to the UFX." }
 }
 func receiveHost(_ bytes:[UInt8]) {
  trace("HOST → BRIDGE",bytes)
  guard mode == .mcu else { return }
  for message in hostParser.feed(bytes) {
   if let reply=handshake.reply(to:message) {
    send(reply)
    append("MCU handshake: reply \(reply.map {String(format:"%02X",$0)}.joined(separator:" "))")
   }
  }
 }
 func releaseAll() {
  for (key,bytes) in activeReleases {
   send(bytes);pulseGeneration[key,default:0] += 1
  }
  activeReleases.removeAll()
 }
 @objc func saveChannel() { defaults.set(channel.indexOfSelectedItem,forKey:"channel") }
 @objc func saveNote(_ sender:NSTextField) { if mode == .custom { _ = note(sender.tag) } }
 func note(_ command:Int) -> Int? {
  guard let field=fields[command],let n=Int(field.stringValue.trimmingCharacters(in:.whitespaces)),(0...127).contains(n) else { append("Invalid note number: enter a whole number from 0 to 127.");return nil }
  defaults.set(n,forKey:"note.\(command)");return n
 }
 func name(_ endpoint:MIDIEndpointRef)->String {
  var value:Unmanaged<CFString>?
  if MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&value)==noErr,let value=value {return value.takeRetainedValue() as String}
  return "MIDI Input \(endpoint)"
 }
 func sourceIdentity(_ endpoint:MIDIEndpointRef) -> RememberedInput {
  func string(_ property:CFString) -> String? {
   var value:Unmanaged<CFString>?
   guard MIDIObjectGetStringProperty(endpoint,property,&value) == noErr,let value=value else { return nil }
   let text=value.takeRetainedValue() as String
   return text.isEmpty ? nil : text
  }
  var id:Int32=0
  let hasID=MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&id) == noErr && id != 0
  return RememberedInput(uniqueID:hasID ? id : nil,name:name(endpoint),
                         manufacturer:string(kMIDIPropertyManufacturer),model:string(kMIDIPropertyModel))
 }
 func restoreVirtualIdentity(_ endpoint:MIDIEndpointRef,key:String) throws {
  if let stored=defaults.object(forKey:key) as? NSNumber,stored.int32Value != 0 {
   try check(MIDIObjectSetIntegerProperty(endpoint,kMIDIPropertyUniqueID,stored.int32Value),
             "Restore virtual port identity (quit other bridge instances if this fails)")
  }
  var id:Int32=0
  try check(MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&id),"Read virtual port identity")
  defaults.set(id,forKey:key)
 }
 func remember(_ endpoint:MIDIEndpointRef) {
  if let data=try? JSONEncoder().encode(sourceIdentity(endpoint)) { defaults.set(data,forKey:"rememberedInput") }
  defaults.set(false,forKey:"inputAutoConnectDisabled")
 }
 func scheduleRefresh() {
  refreshWork?.cancel()
  let work=DispatchWorkItem { [weak self] in self?.refresh(nil) }
  refreshWork=work
  DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
 }
 func connectionStatus(_ message:String) {
  guard status.stringValue != message else { return }
  status.stringValue=message;append(message);updateStatusMenu()
 }
 func disconnectInput() {
  connectionGeneration &+= 1
  if selected != 0 { MIDIPortDisconnectSource(port,selected) }
  selected=0;parser=Parser();releaseAll()
 }
 func connectInput(_ endpoint:MIDIEndpointRef) {
  disconnectInput()
  let result=MIDIPortConnectSource(port,endpoint,UnsafeMutableRawPointer(bitPattern:connectionGeneration))
  if result == noErr {
   selected=endpoint;remember(endpoint)
   connectionStatus("Connected: \(name(endpoint)) · MIDI processing active")
  } else {
   connectionStatus("Connection failed: \(result). Retrying automatically.")
  }
 }
 @objc func refresh(_ sender:Any?) {
  guard enabled else { return }
  sources=(0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter {
   guard $0 != output && $0 != 0 else { return false }
   var offline:Int32=0
   return MIDIObjectGetIntegerProperty($0,kMIDIPropertyOffline,&offline) != noErr || offline == 0
  }
  input.removeAllItems();input.addItem(withTitle:"— Select input —");input.addItems(withTitles:sources.map(name))
  if selected != 0,let i=sources.firstIndex(of:selected) { input.selectItem(at:i+1);remember(selected);return }
  if selected != 0 { disconnectInput() }
  let saved=rememberedInput
  let choice=chooseInput(sources.map { InputSource(endpoint:$0,identity:sourceIdentity($0)) },
                         remembered:saved,disabled:defaults.bool(forKey:"inputAutoConnectDisabled"))
  switch choice {
  case .connect(let endpoint):
   if let i=sources.firstIndex(of:endpoint) { input.selectItem(at:i+1) }
   connectInput(endpoint)
  case .disabled:
   connectionStatus("Input disconnected. Select a device to enable automatic reconnection.")
  case .ambiguous:
   connectionStatus("Multiple matching MIDI inputs. Select the intended device once.")
  case .missing:
   connectionStatus(saved.map { "Waiting for \($0.name) · reconnects automatically" } ?? "Select your MP10 MIDI input port once to remember it.")
  }
 }
 @objc func selectInput() {
  let index=input.indexOfSelectedItem-1
  guard sources.indices.contains(index) else {
   disconnectInput()
   defaults.removeObject(forKey:"rememberedInput")
   defaults.set(true,forKey:"inputAutoConnectDisabled")
   connectionStatus("Input disconnected. Select a device to enable automatic reconnection.")
   return
  }
  let endpoint=sources[index]
  guard (0..<MIDIGetNumberOfSources()).contains(where:{MIDIGetSource($0) == endpoint}) else {
   refresh(nil);return
  }
  // Save an explicit choice even if the driver is still becoming ready.
  remember(endpoint)
  connectInput(endpoint)
 }
 func receive(_ bytes:[UInt8]) {
  guard selected != 0 else {return}
  trace("INPUT → BRIDGE",bytes)
  guard mode != .monitor else { return }
  for (command,raw) in parser.feed(bytes) {
   let title=commands.first {$0.0==command}?.1 ?? "Unknown"
   append("IN \(raw.map {String(format:"%02X",$0)}.joined(separator:" ")) · \(title)")
   trigger(command)
  }
 }
 @objc func testNote(_ sender:NSButton) {trigger(sender.tag)}
 func trigger(_ command:Int) {
  guard enabled,mode != .monitor else { return }
  let custom = mode == .custom ? note(command) : nil
  guard let pulse=makePulse(command:command,mode:mode,customNote:custom,channel:channel.indexOfSelectedItem) else {
   if mode == .mcu { append("MCU: This MMC command is unassigned and will be ignored.") }
   return
  }
  let key=pulse.key
  if let previous=activeReleases[key] { send(previous) }
  activeReleases[key]=pulse.release
  pulseGeneration[key,default:0] += 1
  let generation=pulseGeneration[key]!
  send(pulse.press)
  append("OUT \(mode == .mcu ? "MCU" : "Note") \(pulse.press[1]), channel \(Int(pulse.press[0] & 0x0F)+1), Velocity \(pulse.press[2])")
  DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
   guard let self=self,self.pulseGeneration[key]==generation else {return}
   self.send(pulse.release);self.activeReleases.removeValue(forKey:key)
  }
 }
 var pulseGeneration:[Int:Int]=[:]
 func send(_ bytes:[UInt8]) {
  let result = withSourcePacket(bytes) { list in
   trace("BRIDGE → HOST",bytes,hostTime:list.pointee.packet.timeStamp)
   return MIDIReceived(output,list)
  }
  if result != noErr {append("Send failed: \(result)")}
 }
 @objc func copyLog() {
  let report="MP10 Reason Bridge 1.5\nMode: \(modeSelector.titleOfSelectedItem ?? "unknown")\nInput: \(selected == 0 ? "none" : name(selected))\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nRaw entries use monotonic seconds at callback processing time, not hardware packet timestamps. Generated source packets carry current Mach host time.\n\n" + logLines.joined(separator:"\n")
  NSPasteboard.general.clearContents();NSPasteboard.general.setString(report,forType:.string)
 }
 @objc func clearLog() { logLines=[];log.string="" }
 func trace(_ direction:String,_ bytes:[UInt8],hostTime:MIDITimeStamp? = nil) {
  guard rawLog.state == .on,!bytes.isEmpty else { return }
  let timestamp=String(format:"%.3f",ProcessInfo.processInfo.systemUptime)
  let packetTime=hostTime.map { " host_ticks=\($0)" } ?? ""
  for offset in stride(from:0,to:bytes.count,by:128) {
   let chunk=bytes[offset..<min(offset+128,bytes.count)]
   append("\(timestamp) \(direction)\(packetTime) [\(offset)..<\(offset+chunk.count) of \(bytes.count)]: \(chunk.map{String(format:"%02X",$0)}.joined(separator:" "))")
  }
 }
 func append(_ message:String) {
  logLines.append(message);if logLines.count>1000 {logLines.removeFirst(logLines.count-1000)}
  log.string=logLines.joined(separator:"\n");log.scrollToEndOfDocument(nil)
 }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
 func applicationWillTerminate(_ notification:Notification) {
  if let item=statusItem { NSStatusBar.system.removeStatusItem(item) };statusItem=nil
  refreshWork?.cancel();reconnectTimer?.invalidate()
  saveCustomNotes()
  disconnectInput()
  if client != 0 {MIDIClientDispose(client)}
 }
}

func selfTest() {
 let remembered=RememberedInput(uniqueID:42,name:"USB-MIDI",manufacturer:"Kawai",model:"MP10")
 let serialized=try! JSONEncoder().encode(remembered)
 let restored=try! JSONDecoder().decode(RememberedInput.self,from:serialized)
 precondition(restored == remembered)
 let unrelated=InputSource(endpoint:20,identity:RememberedInput(uniqueID:7,name:"Other MP10",manufacturer:"Other",model:nil))
 let original=InputSource(endpoint:10,identity:remembered)
 precondition(chooseInput([original,unrelated],remembered:restored,disabled:false) == .connect(10))
 precondition(chooseInput([unrelated],remembered:restored,disabled:false) == .missing)
 let replugged=InputSource(endpoint:99,identity:remembered)
 precondition(chooseInput([unrelated,replugged],remembered:restored,disabled:false) == .connect(99))
 let changedID=InputSource(endpoint:101,identity:RememberedInput(uniqueID:123,name:"USB-MIDI",manufacturer:"Kawai",model:"MP10"))
 precondition(chooseInput([changedID],remembered:restored,disabled:false) == .connect(101))
 precondition(chooseInput([changedID,InputSource(endpoint:102,identity:changedID.identity)],remembered:restored,disabled:false) == .ambiguous)
 let wrongDevice=InputSource(endpoint:21,identity:RememberedInput(uniqueID:8,name:"USB-MIDI",manufacturer:"Other",model:"MP10"))
 precondition(chooseInput([wrongDevice],remembered:restored,disabled:false) == .missing)
 precondition(chooseInput([original],remembered:restored,disabled:true) == .disabled)
 precondition(chooseInput([unrelated],remembered:nil,disabled:false) == .connect(20))
 precondition(chooseInput([original,unrelated],remembered:nil,disabled:true) == .disabled)
 precondition(chooseInput([InputSource(endpoint:30,identity:RememberedInput(uniqueID:9,name:"MP10 A",manufacturer:nil,model:nil)),unrelated],remembered:nil,disabled:false) == .ambiguous)
 // Exercise the production packet builder, not just the MIDI payload parser.
 let fixtures: [[UInt8]] = [[0x90,0x5E,0x7F],[0x90,0x5E,0],
  [0x90,0x5D,0x7F],[0x90,0x5D,0],[0x90,0x5F,0x7F],
  [0x90,0x5B,0x7F],[0x90,0x5C,0x7F],
  [0xF0,0,0,0x66,0x14,1]+Array("MP10BRG".utf8)+[1,2,3,4,0xF7],
  Array(repeating:0x01,count:256)]
 for bytes in fixtures {
  var deliveries=0
  let before=mach_absolute_time()
  let result=withSourcePacket(bytes) { list in
   deliveries += 1
   precondition(list.pointee.numPackets == 1)
   precondition(list.pointee.packet.timeStamp > 0)
   precondition(list.pointee.packet.timeStamp >= before)
   precondition(list.pointee.packet.timeStamp <= mach_absolute_time())
   precondition(packetBytes(list) == bytes)
   return OSStatus(-1234) // Delivery errors must propagate to the caller.
  }
  precondition(deliveries == 1 && result == -1234)
 }
 for invalid in [[],Array(repeating:UInt8(1),count:257)] {
  precondition(withSourcePacket(invalid) { _ in preconditionFailure("Invalid packet was delivered") } == -50)
 }
 var p=Parser()
 precondition(p.feed([0xF0,0x7F,0x7F]).isEmpty)
 precondition(p.feed([0x06,0x02,0xF7]).map{$0.0} == [2])
 precondition(p.feed([0xF0,0x7F,0,0x06,0xF8,1,0xF7,0xFA,0xFB,0xFC]).map{$0.0} == [1,250,251,252])
 precondition(p.feed([0xF0,0x7E,0,6,2,0xF7,0x90,60,100]).isEmpty)
 precondition(p.feed([0xF0,0x7F,0,6,2,1,0xF7]).isEmpty)
 precondition(p.feed([0xF0,0x7F,0,6,2,0x90,60,100,0xF7]).isEmpty)
 for device in [UInt8(0),1,127] {
  for command in UInt8(1)...13 {
   precondition(p.feed([0xF0,0x7F,device,6,command,0xF7]).map{$0.0} == [Int(command)])
  }
 }
 precondition(p.feed([0xF0]+Array(repeating:1,count:2000)+[0xF7]).isEmpty)
 precondition(p.feed([0xF0,0x7F,0,6,3,0xF7]).map{$0.0} == [3])
 precondition(Set(commands.map{defaultNote($0.0)}).count == commands.count)
 let expectedMCU: [Int:Int] = [1:93,2:94,3:94,4:92,5:91,6:95,250:94,251:94,252:93]
 for (command,_) in commands {
  if let n = expectedMCU[command] {
   // MCU must ignore both custom note and channel settings.
   let actual=makePulse(command:command,mode:.mcu,customNote:12,channel:15)
   precondition(actual == NotePulse(press:[0x90,UInt8(n),127],release:[0x90,UInt8(n),0]))
  } else { precondition(makePulse(command:command,mode:.mcu,customNote:94,channel:0) == nil) }
 }
 for n in [0,94,127] {
  for ch in [0,7,15] {
   let actual=makePulse(command:9,mode:.custom,customNote:n,channel:ch)
   precondition(actual == NotePulse(press:[UInt8(0x90+ch),UInt8(n),100],release:[UInt8(0x80+ch),UInt8(n),0]))
  }
 }
 for (command,_) in commands {
  precondition(makePulse(command:command,mode:.monitor,customNote:94,channel:0) == nil)
 }
 precondition(makePulse(command:2,mode:.custom,customNote:128,channel:0) == nil)
 precondition(makePulse(command:2,mode:.custom,customNote:nil,channel:0) == nil)
 precondition(makePulse(command:2,mode:.custom,customNote:94,channel:16) == nil)
 var h=MCUHandshake()
 let hdr=h.header
 let serial=h.serial
 precondition(h.reply(to:hdr+[2]+serial+[5,5,123,47,0xF7]) == nil) // no query yet
 precondition(h.reply(to:hdr+[0,0xF7]) == hdr+[1]+serial+[1,2,3,4,0xF7])
 // Independent known challenge vector, not an expected value computed by the implementation.
 precondition(MCUHandshake.response([1,2,3,4]) == [5,5,123,47])
 precondition(h.reply(to:hdr+[2]+serial+[5,5,123,47,0xF7]) == hdr+[3]+serial+[0xF7])
 precondition(h.reply(to:hdr+[2]+serial+[5,5,123,47,0xF7]) == nil) // stale reply
 _ = h.reply(to:hdr+[0,0xF7])
 precondition(h.reply(to:hdr+[2]+Array("WRONGID".utf8)+[5,5,123,47,0xF7]) == nil)
 precondition(h.reply(to:hdr+[2]+serial+[0,0,0,0,0xF7]) == hdr+[4]+serial+[0xF7])
 precondition(h.reply(to:[0xF0,0,0,0x66,0x15,0,0xF7]) == nil)
 precondition(h.reply(to:hdr+[0,1,0xF7]) == nil)
 precondition(h.reply(to:hdr+[0x13,0,0xF7]) == hdr+[0x14]+Array("V1.5 ".utf8)+[0xF7])
 _ = h.reply(to:hdr+[0x63,0xF7])
 precondition(h.awaitingReply)
 _ = h.reply(to:hdr+[0x0F,0x7F,0xF7])
 precondition(!h.awaitingReply)
 var stream=SysExStream()
 precondition(stream.feed([0x90,94,127]+Array(hdr.prefix(3))).isEmpty)
 precondition(stream.feed(Array(hdr.dropFirst(3))+[0xF8,0,0xF7]) == [hdr+[0,0xF7]])
 precondition(stream.feed(hdr+[0,0xF7]+hdr+[0x13,0,0xF7]).count == 2)
 print("PASS: Remembered-input persistence, reconnect matching and ambiguity checks passed. Production CoreMIDI packet builder: current nonzero host timestamps, captured UFX transport bytes, SysEx, boundary lengths and delivery errors. MMC parser, MCU mappings, custom notes, monitor mode and handshake tests also passed.")

}
func integrationTest() throws {
 let app = NSApplication.shared
 app.setActivationPolicy(.prohibited)
 let bridge = Bridge()
 let suite = "de.local.mp10reasonbridge.test." + UUID().uuidString
 bridge.defaults = UserDefaults(suiteName:suite)!
 defer {bridge.defaults.removePersistentDomain(forName:suite)}
 bridge.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
 guard bridge.enabled else {throw NSError(domain:"Test",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not start CoreMIDI: \(bridge.status.stringValue)"])}
 bridge.window.orderOut(nil)
 var testClient=MIDIClientRef(), fake=MIDIEndpointRef(), receiver=MIDIPortRef()
 try check(MIDIClientCreateWithBlock("Bridge Test" as CFString,&testClient,nil),"Test client")
 defer {if let item=bridge.statusItem { NSStatusBar.system.removeStatusItem(item) };bridge.reconnectTimer?.invalidate();bridge.refreshWork?.cancel();MIDIClientDispose(testClient);MIDIClientDispose(bridge.client)}
 try check(MIDISourceCreate(testClient,"MP10 Test Source" as CFString,&fake),"Test input")
 var received:[UInt8]=[]
 var receivedTimeStamps:[MIDITimeStamp]=[]
 try check(MIDIInputPortCreateWithBlock(testClient,"Test Receiver" as CFString,&receiver) { list,_ in
  var collected:[UInt8]=[]
  var stamps:[MIDITimeStamp]=[]
  var packet=UnsafeRawPointer(list).advanced(by:MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to:MIDIPacket.self)
  for _ in 0..<list.pointee.numPackets {
   stamps.append(packet.pointee.timeStamp)
   let data=UnsafeRawPointer(packet).advanced(by:MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to:UInt8.self)
   collected.append(contentsOf:UnsafeBufferPointer(start:data,count:Int(packet.pointee.length)))
   packet=UnsafePointer(MIDIPacketNext(packet))
  }
  DispatchQueue.main.async {
   received.append(contentsOf:collected)
   receivedTimeStamps.append(contentsOf:stamps)
  }
 },"Test receiver")
 try check(MIDIPortConnectSource(receiver,bridge.output,nil),"Connect test output")
 bridge.refresh(nil)
 guard let index=bridge.sources.firstIndex(of:fake) else {fatalError("Test source missing")}
 bridge.input.selectItem(at:index+1);bridge.selectInput()
 // Two packets in one callback exercise packet traversal and fragmented SysEx.
 var list=MIDIPacketList()
 withUnsafeMutablePointer(to:&list) { pointer in
  var packet=MIDIPacketListInit(pointer)
  for chunk:[UInt8] in [[0xF0,0x7F,0x7F],[0x06,0x02,0xF7]] {
   packet=chunk.withUnsafeBufferPointer {MIDIPacketListAdd(pointer,MemoryLayout<MIDIPacketList>.size,packet,mach_absolute_time(),$0.count,$0.baseAddress!)}
  }
  precondition(MIDIReceived(fake,pointer)==noErr)
 }
 let deadline=Date().addingTimeInterval(2)
 while received.count<6 && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == [0x90,94,127,0x90,94,0],"Unexpected MCU output: \(received)")
 precondition(receivedTimeStamps.count >= 2 && receivedTimeStamps.allSatisfy { $0 > 0 })
 precondition(receivedTimeStamps.last! >= receivedTimeStamps.first!)
 received=[]
 bridge.modeSelector.selectItem(at:1);bridge.changeMode()
 bridge.channel.selectItem(at:15)
 bridge.fields[2]!.stringValue="77"
 bridge.trigger(2)
 let customDeadline=Date().addingTimeInterval(2)
 while received.count<6 && Date()<customDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == [0x9F,77,100,0x8F,77,0],"Unexpected custom output: \(received)")
 received=[]
 bridge.modeSelector.selectItem(at:0);bridge.changeMode()
 precondition(bridge.fields[2]!.stringValue == "94")
 precondition(bridge.defaults.integer(forKey:"note.2") == 77)
 var hostPort=MIDIPortRef()
 try check(MIDIOutputPortCreate(testClient,"Test Host Output" as CFString,&hostPort),"Host output")
 func sendHost(_ bytes:[UInt8]) {
  var hostList=MIDIPacketList()
  withUnsafeMutablePointer(to:&hostList) { pointer in
   let packet=MIDIPacketListInit(pointer)
   bytes.withUnsafeBufferPointer { _ = MIDIPacketListAdd(pointer,MemoryLayout<MIDIPacketList>.size,packet,0,$0.count,$0.baseAddress!) }
   precondition(MIDISend(hostPort,bridge.feedback,pointer) == noErr)
  }
 }
 sendHost([0x90,94,127]) // LED feedback must not be echoed as Play.
 bridge.trigger(9) // MMC Pause is deliberately unassigned.
 RunLoop.current.run(until:Date().addingTimeInterval(0.12))
 precondition(received.isEmpty)
 let handshake=MCUHandshake()
 sendHost(handshake.header+[0,0xF7])
 let queryDeadline=Date().addingTimeInterval(2)
 while received.count<18 && Date()<queryDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == handshake.header+[1]+handshake.serial+handshake.challenge+[0xF7])
 received=[]
 sendHost(handshake.header+[2]+handshake.serial+[5,5,123,47,0xF7])
 let replyDeadline=Date().addingTimeInterval(2)
 while received.count<14 && Date()<replyDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == handshake.header+[3]+handshake.serial+[0xF7])
 bridge.modeSelector.selectItem(at:1);bridge.changeMode()
 precondition(bridge.fields[2]!.stringValue == "77")
 // Closing the window must leave CoreMIDI and the selected input alive.
 bridge.modeSelector.selectItem(at:0);bridge.changeMode()
 let connectedBeforeHide=bridge.selected
 bridge.window.performClose(nil)
 precondition(!bridge.window.isVisible && bridge.selected == connectedBeforeHide && bridge.enabled)
 precondition(bridge.statusItem != nil)
 precondition(!bridge.applicationShouldTerminateAfterLastWindowClosed(app))
 received=[]
 try check(withSourcePacket([0xF0,0x7F,0x7F,6,1,0xF7]) { MIDIReceived(fake,$0) },"Send while hidden")
 let hiddenDeadline=Date().addingTimeInterval(2)
 while received.count<6 && Date()<hiddenDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == [0x90,93,127,0x90,93,0])
 bridge.showWindow(nil)
 precondition(bridge.window.isVisible && bridge.selected == connectedBeforeHide)
 if let minimize=bridge.window.standardWindowButton(.miniaturizeButton) { minimize.performClick(nil) }
 precondition(!bridge.window.isVisible && bridge.selected == connectedBeforeHide)
 // Remove/recreate the source and verify reconnect actually resumes translation.
 let saved=bridge.rememberedInput!
 let previousGeneration=bridge.connectionGeneration
 try check(MIDIEndpointDispose(fake),"Unplug test source")
 bridge.refresh(nil)
 precondition(bridge.selected == 0 && bridge.rememberedInput == saved)
 try check(MIDISourceCreate(testClient,"MP10 Test Source" as CFString,&fake),"Replug test source")
 if let id=saved.uniqueID { try check(MIDIObjectSetIntegerProperty(fake,kMIDIPropertyUniqueID,id),"Restore test source identity") }
 bridge.refresh(nil)
 precondition(bridge.selected == fake && bridge.connectionGeneration != previousGeneration)
 bridge.modeSelector.selectItem(at:0);bridge.changeMode()
 received=[]
 try check(withSourcePacket([0xF0,0x7F,0x7F,6,2,0xF7]) { MIDIReceived(fake,$0) },"Send after reconnect")
 let reconnectDeadline=Date().addingTimeInterval(2)
 while received.count<6 && Date()<reconnectDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
 precondition(received == [0x90,94,127,0x90,94,0])
 bridge.input.selectItem(at:0);bridge.selectInput();bridge.refresh(nil)
 precondition(bridge.selected == 0 && bridge.defaults.bool(forKey:"inputAutoConnectDisabled"))
 // Verify saved virtual IDs survive endpoint recreation, as on an app restart.
 let outputID=bridge.defaults.integer(forKey:"virtualOutputID")
 try check(MIDIEndpointDispose(bridge.output),"Recreate virtual output")
 try check(MIDISourceCreate(bridge.client,"MP10 Reason Bridge" as CFString,&bridge.output),"Restart virtual output")
 try bridge.restoreVirtualIdentity(bridge.output,key:"virtualOutputID")
 var restoredID:Int32=0
 try check(MIDIObjectGetIntegerProperty(bridge.output,kMIDIPropertyUniqueID,&restoredID),"Read restarted output ID")
 precondition(Int(restoredID) == outputID)
 print("PASS: CoreMIDI delivery, both modes, preferences, feedback, handshake, unplug/replug with resumed translation, explicit disconnect, virtual-port identity persistence, and MIDI delivery with the window hidden.")
}
if CommandLine.arguments.contains("--self-test") {selfTest()}
else if CommandLine.arguments.contains("--integration-test") {
 do {try integrationTest()} catch {fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
}
else {
 let app=NSApplication.shared
 let delegate=Bridge()
 app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
}
