# Roadmap

Porch Light does one job: remote sessions. Anything on this list has to serve that job.

## Done

- **Sessions.** `porchlight session start`, `resize`, `status`, `presets` and `end`. A virtual screen sized for the client becomes the main display and the desk monitors turn off. When the session ends, every monitor comes back with its mode, refresh rate and position.
- **The guardian.** A LaunchAgent that relaunches Porch Light if it dies mid-session, up to twice without 5 healthy minutes between, and otherwise brings the monitors back itself. Plus `porchlight rescue`, emergency hotkeys, and an alert window that stays visible during a screen share.
- **Presets.** Saved sizes, with an editor in the menu bar ("Edit Presets...") and per-monitor refresh rate pins.
- **Session API v1.** Session start and end with owner processes, the virtual screen's display ID and UUID as JSON, `porchlight session watch`, distributed notifications, and the `PorchLightClient` Swift library. See [`session-api.md`](session-api.md).
- **Size per device.** Map a client's network address to a preset (`porchlight clients set`).
- **Match client.** A device with no preset gets a HiDPI screen matched to the screen size its Parsec client reports. Phones are trimmed so the notch falls in the black bars, and get a little extra room (`porchlight clients match`, `notch`, `room`).

## Next

- **A notarized download.** A signed, notarized installer on GitHub Releases that installs the app, the guardian and the CLI, so building from source becomes optional.
- **A first-run screen** that explains the guardian and Launch at Login.

## Later, if needed

- If a session start ever stalls when the last monitor turns off, move that display call to the main thread.
- Follow a client that changes its screen size mid-session (for example, rotating a tablet).

## Not planned

- Everyday display work: brightness, DDC, color, HDR, picture in picture, mirroring. Dedicated display utilities do that well, and Porch Light runs alongside them.
- The Mac App Store (Porch Light uses display APIs the store doesn't allow), Intel Macs, and macOS older than 26.
- Localization, for now. Porch Light is English only.
