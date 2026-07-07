# CedarScan

iPhone LiDAR room-scanning app (CubiCasa-style), built on Apple's RoomPlan framework.

**Features**
- Scan rooms with LiDAR using Apple's guided AR capture UI (RoomPlan / RoomCaptureView)
- Multi-room scanning in one session, merged into a single structure (StructureBuilder)
- 3D model viewer (USDZ via QuickLook, includes AR placement mode)
- Auto-generated 2D floor plan: walls, doors, windows, openings, furniture, per-wall dimensions and floor area
- Export & share: USDZ 3D model, PNG floor plan
- Vietnamese UI

**Requirements**
- iPhone Pro (12 Pro or later) or iPad Pro with LiDAR sensor
- iOS 17.0+

**Build**
No Mac needed — GitHub Actions builds an unsigned IPA on every push to `main` (see `.github/workflows/build.yml`). Download the `CedarScan-ipa` artifact and sideload it (e.g. with AltStore). The Xcode project is generated on CI by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

To build locally on a Mac instead:

```sh
brew install xcodegen
xcodegen generate
open CedarScan.xcodeproj
```

See [HUONG-DAN.md](HUONG-DAN.md) for the full Vietnamese user guide.
