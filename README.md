# MP10 Reason Bridge

> **1.3 diagnostic preview 2:** Generated virtual-source MIDI packets now carry current Mach host timestamps instead of zero, correcting a CoreMIDI API-contract violation. This branch also includes raw MIDI capture for comparing the UFX1604 with the MP10 bridge. The timing defect is confirmed; the complete Reason fix awaits a target-Mac retest. See [the capture instructions](DIAGNOSTICS.txt). The stable release remains v1.2.

A free, native macOS utility that translates the **Kawai MP10's MIDI Machine Control (MMC) transport messages** into **Mackie Control Universal (MCU) button messages** for Reason. A custom MIDI-note mode is also included.

The bridge creates its own virtual MIDI ports. Bome MIDI Translator, an IAC bus, and third-party libraries are not required.

**Status:** the universal app builds for Apple Silicon and Intel, and protocol self-tests pass. End-to-end operation with a physical MP10 and Reason 14 on macOS Tahoe has **not yet been verified**. The development environment does not permit the CoreMIDI/GUI integration test to run.

## Download and requirements

Download the app ZIP from [Releases](https://github.com/rommelfs/mp10-reason-bridge/releases/latest), extract it, and open **MP10 Reason Bridge.app**. Keep the app running while using the transport controls.

- macOS 13 or later; Apple Silicon or Intel Mac.
- Kawai MP10 connected over USB MIDI or a MIDI interface.
- Reason 14 is the intended host. Other MCU-capable hosts may work but have not been tested.
- No development tools are required to run the downloaded app.

The app is ad-hoc signed, **not Apple-notarized**. If macOS blocks it as an unidentified developer, review the app and use **System Settings → Privacy & Security → Open Anyway** if appropriate.

Version 1.2 uses English throughout the interface, status messages, logs, and test output. Quit an older bridge before replacing it with the new app. Existing custom mappings and MIDI port names are preserved.

## Connect the MP10

1. Connect the MP10 to your Mac.
2. Start the bridge before opening Reason.
3. Choose the MP10's input in **MIDI Input**. If using a MIDI interface, choose its corresponding port. Click **Refresh** if needed.
4. Enable **TRANSPORT** on the MP10.
5. Press a transport button. The log should show an `IN` message with the decoded command and an `OUT` message with the generated note.

The MP10's button assignments are configurable under **MIDI EDIT → MMC**; see page 46 of the [MP10 manual](https://www.kawai.de/service/mp10.pdf). The incoming command may therefore differ from the button's printed label. Use the log to see what is actually transmitted.

## Set up Reason 14 with Mackie Control

The default **Output mode** is **Mackie Control (MCU)**. Later mode selections are remembered.

1. Open **Reason → Settings → MIDI**.
2. If an older bridge configuration exists, remove its generic controller entry. Keep your actual MP10 keyboard entry.
3. Choose **Add manually**, then **Manufacturer: Mackie**, **Model: Control** (or Control Universal, depending on the name shown).
4. Set the ports as follows:

   | Reason setting | Port |
   | --- | --- |
   | MIDI Input | `MP10 Reason Bridge` |
   | MIDI Output | `MP10 Reason Bridge Feedback` |

5. Keep the actual MP10 as your master keyboard for playing and recording notes.
6. Test Play, Stop, Record, Rewind, and Fast Forward.

This setup uses Reason's built-in Mackie mapping rather than individual Remote Overrides. **Add the surface manually:** automatic detection is not guaranteed. The bridge implements a transport subset and basic connection messages, not a complete Mackie mixing console.

Avoid multiple active Reason control-surface entries using the same bridge input. Older overrides associated with a generic bridge controller are not needed for this MCU setup.

## MCU mapping

All MCU button messages use **MIDI channel 1**:

| Input from MP10 | MCU button | Note number | Hex |
| --- | --- | ---: | --- |
| MMC Stop (`01`) | Stop | 93 | `5D` |
| MMC Play (`02`) | Play | 94 | `5E` |
| MMC Deferred Play (`03`) | Play | 94 | `5E` |
| MMC Fast Forward (`04`) | Fast Forward | 92 | `5C` |
| MMC Rewind (`05`) | Rewind | 91 | `5B` |
| MMC Record Strobe (`06`) | Record | 95 | `5F` |
| MIDI Realtime Start / Continue (`FA` / `FB`) | Play | 94 | `5E` |
| MIDI Realtime Stop (`FC`) | Stop | 93 | `5D` |

A press is **Note On, velocity 127**. After 80 ms, release is sent as **Note On, velocity 0**. For example:

```text
Play press:    90 5E 7F
Play release:  90 5E 00
```

The channel and notes are fixed in MCU mode. These values are protocol button IDs; they do not represent musical pitches here.

MMC Record Exit, Record Pause, Pause, Eject, Chase, Command Error Reset, and MMC Reset have no mapping in this mode. Their fields show `—`, their **Send** buttons are disabled, and incoming messages are logged and ignored. No unrelated MCU buttons are substituted for them.

### Host return path and handshake

`MP10 Reason Bridge Feedback` receives host messages separately from the MP10 input. For model ID `14` hex, the bridge handles Device Query, Host Connection Reply, Firmware Version Request, and Reset, using the virtual serial identifier `MP10BRG`. Connection replies appear in the log as `MCU handshake`.

LED, display, and fader feedback is ignored. It is never echoed as a button press, and it is not forwarded to the MP10.

## Custom MIDI-note mode

Choose **Custom MIDI notes** to assign any note number from 0–127 to each of the 16 recognized commands. The output channel is selectable from 1–16.

Existing custom assignments are preserved when switching to MCU mode and restored when switching back. Settings are stored locally using macOS user defaults. Press Enter, trigger a command, switch modes, or quit normally to save edited note values.

Custom-mode output uses Note On with velocity 100, followed after 80 ms by Note Off with velocity 0. This is a separate mode; its default assignments are **not an MCU mapping**. The legacy defaults include Play 94, Stop 95, and Deferred Play 96.

To use this mode in Reason:

1. Disable or remove the Mackie entry using the bridge port.
2. Add **Other → MIDI Control Keyboard**, using `MP10 Reason Bridge` as input and no MIDI output. Use a model with a keyboard so that notes are available as controls.
3. Right-click / Control-click a Reason transport control and choose **Edit Remote Override Mapping**.
4. Enable **Learn From Control Surface Input**, then press the MP10 button or the corresponding **Send** button in the bridge.
5. If learning does not select the note, manually choose the bridge surface, **Keyboard**, and the note number.
6. Save the Reason song. Remote Overrides are stored with the song; save a template if you want them in new songs.

Use different notes for commands that should be distinguishable. Octave labels differ between applications; use the numeric note ID rather than the displayed pitch name.

## Limitations and troubleshooting

- Each input event produces an 80 ms press. **Holding an MP10 button does not produce continuous held-button rewind or fast-forward.**
- Keyboard notes, CC messages, MIDI Clock, and unrelated SysEx are not passed through. Route your MP10 keyboard directly to Reason as before.
- MMC input accepts any device ID from 0–127. The bridge parses simple six-byte MMC commands `01`–`0D`, including messages fragmented across MIDI packets.
- The bridge does not reflect Reason's playback state or LEDs on the MP10.
- If no input appears, check the connection, select the correct input, and click **Refresh**.
- If transport events do not appear in the log, check **TRANSPORT** and the MP10's MMC assignments.
- If Reason cannot see a virtual port, start the bridge first and reopen Reason if needed. Check the bridge's status line for CoreMIDI errors.
- If notes sound instead of controlling transport, check that the bridge mode matches the Reason controller setup and that the actual MP10 remains the master keyboard.
- If an action fires twice, check for duplicate active surface entries using the bridge input.

## Build from source

Install Xcode or the Xcode Command Line Tools, then run:

```sh
git clone https://github.com/rommelfs/mp10-reason-bridge.git
cd mp10-reason-bridge
./build.command
```

The script compiles both `arm64` and `x86_64` for macOS 13+, combines them into a universal app, applies an ad-hoc signature, and runs the protocol self-tests. The app is written to `MP10 Reason Bridge.app` in the repository directory. It has no package dependencies.

## Tests

Run the protocol self-tests without opening a GUI or starting CoreMIDI:

```sh
"MP10 Reason Bridge.app/Contents/MacOS/MP10ReasonBridge" --self-test
```

These cover the production packet builder (valid nonzero host timestamps, captured UFX payloads, buffer limits and delivery errors), MMC parsing and fragmentation, realtime messages, invalid input, MCU mappings and exact press/release bytes, custom notes and channels, unmapped commands, and handshake success/error cases.

On a Mac with a graphical session and CoreMIDI available, run:

```sh
"MP10 Reason Bridge.app/Contents/MacOS/MP10ReasonBridge" --integration-test
```

This briefly opens a test window and creates a virtual MP10 and test receiver. It checks packet traversal, both output modes, preservation of custom assignments, feedback without echo, and the handshake over virtual MIDI ports. It uses a separate temporary preferences domain. It does not replace testing with a physical MP10 and Reason.

## Source files

- `Bridge.swift`: app, stream parsers, translation rules, host handshake, and tests.
- `Info.plist`: app metadata and minimum macOS version.
- `build.command`: universal build, signing, and protocol self-test script.

## References

- [Kawai MP10 manual](https://www.kawai.de/service/mp10.pdf), MIDI section and MMC assignments, pages 31 and 46.
- [Reason 14 Remote documentation](https://docs.reasonstudios.com/reason14/remote-playing-and-controlling-devices).
- [Mackie/Emagic Logic Control manual](https://htlab.net/computer/protocol/mackie-control/LogicControl_EN.pdf), MIDI implementation: switches and host connection.
- [MCU protocol research based on original hardware](https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md), model IDs and MCU extensions.

## License

[MIT](LICENSE.txt). This is an independent project and is not affiliated with Kawai, Reason Studios, or Mackie.
