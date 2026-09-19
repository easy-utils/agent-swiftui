# agent-swiftui-app

SwiftUI port of the Flutter agent app (`easy-utils/agent-flutter`) over
`agent-sdk-swift` (agent.v1.AgentService via easy-rpc). Full page/feature
parity: setup gate + backend manager, session list (search / multi-select /
unread badges / live watchSessions), chat (local-first sqlite mirror,
tip-anchored sync, streaming bubbles with reasoning/tool cards, drafts,
attachments, voice, settings sheet), mailbox, config (appearance, backends,
providers + gateway + model forms with live tests, presets, tools with
per-knob config) and zh/en i18n (354 keys).

## Build

Requires a full Xcode toolchain (Xcode 16.3+ / Swift 6.1+); the generated
protobuf sources use `nonisolated` declarations that the older Command Line
Tools-only Swift 6.0 compiler rejects.

```bash
cd easy-utils/agent-swiftui-app
swift build -c release                      # macOS, host arch
swift build -c release --arch arm64 --arch x86_64   # universal2
# iOS: open in Xcode, select the agent-app target, run on device/simulator.
```

Packaging the macOS `.app` (SwiftPM only produces the bare executable):

```bash
APP="Easy Agent.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/agent-app "$APP/Contents/MacOS/agent-app"
cp Info.plist "$APP/Contents/Info.plist"   # CFBundleIdentifier easy.agent.swiftui
codesign --force --deep --sign - "$APP"    # ad-hoc
hdiutil create -volname "Easy Agent" -srcfolder "$APP" -ov -format UDZO Easy-Agent.dmg
```

Platforms: macOS 14+ / iOS 17+ (@Observable). Local storage uses the system
SQLite3 (schema identical to the Flutter Drift DB).
