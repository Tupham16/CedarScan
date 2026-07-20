# CedarScan

iPhone app that scans a whole home in 3D with the LiDAR sensor and sends the raw capture to the
Cedar247 drafting team, who return professional 2D floor plans.

The app is the capture and ordering front end. It does **not** generate floor plans on device —
people do that from the mesh and the walkthrough video.

**Features**
- Whole-home LiDAR scanning (ARKit scene reconstruction) producing a single colour-mapped mesh
- Live coaching while you scan — screen border, haptics and optional spoken prompts for walking
  too fast, turning too fast, low light, standing too close, phone overheating, tracking lost
- Live mesh overlay so you can see what has and has not been captured
- Silent walkthrough video recorded alongside the mesh, plus the camera track
- Scans are grouped under a property (address), so a multi-floor home is ordered as one job
- Ordering in app (needs a Cedar247 account with a verified email): packages and add-ons from the
  server catalogue, several floors in one order, payment link, order tracking, deliverable
  download, and revision requests
- Virtual Tour add-on: attach 1–3 photos per room and get a shareable interactive tour
- Delivered scans are removed from the device automatically after 14 days to reclaim space

**Not in this app** (it was, before the RoomPlan flow was removed in July 2026)
- No automatic 2D floor plan, room segmentation, or floor-area measurement on device
- No USDZ export and no floor-plan PNG for new scans
- Scans captured with the old RoomPlan flow can still be viewed, shared and ordered; they just
  cannot be created any more

**What a scan produces on device**
- `model-colored.zip` — `model.obj`, `model.mtl`, `model.glb`, `camera-track.json`
  (falls back to `colored-mesh.ply` if compression fails)
- `scan-video.mp4` — H.264, portrait, no audio track

**Requirements**
- iPhone with a LiDAR sensor. The app gates on
  `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` rather than a model list; the
  in-app wording is "iPhone Pro (12 Pro or newer)". Without LiDAR the scan button is disabled, not
  hidden.
- iOS 17.0+, portrait only
- Camera access. No microphone, location, or photo-library permission is requested.

**Build**
No Mac needed — GitHub Actions builds an unsigned IPA on every push to `main`
(see `.github/workflows/build.yml`). Download the `CedarScan-ipa` artifact and sideload it, e.g.
with AltStore. The Xcode project is generated on CI by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

To build locally on a Mac instead:

```sh
brew install xcodegen
xcodegen generate
open CedarScan.xcodeproj
```

See [HUONG-DAN.md](HUONG-DAN.md) for the full Vietnamese user guide, including install steps.
