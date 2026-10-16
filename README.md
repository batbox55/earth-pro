# Earth Pro for Mac

**Keep your globe on the desktop.**

Earth Pro is a native Swift Mac app for exploring a globe, plotting places, measuring distance and land, and building portable KML projects. Start with free map providers; add your own Google Maps API key when you want supported Google imagery and photorealistic 3D.

Google has announced that new Google Earth Pro desktop downloads end **June 25, 2027**; existing installations can continue working. Earth Pro is an independent Mac alternative for keeping a desktop mapping workflow with supported KML/KMZ projects, measurements, custom pins, and image overlays. See [Google’s announcement](https://support.google.com/earth/thread/448773864). Earth Pro is not affiliated with Google and does not reproduce every Google Earth feature.

[Download for Mac](https://github.com/batbox55/earth-pro/releases/latest) · [Website](https://zachenson.com/earth-pro/) · [Support](https://zachenson.com/earth-pro/support) · [Privacy](https://zachenson.com/earth-pro/privacy)

![Earth Pro plotting custom address pins in Manhattan](docs/screenshots/address-pins.jpg)

*Actual app interface. Apple Maps imagery and third-party content retain their attribution and terms.*

## From an address list to a useful map

- **Plot up to 250 addresses at once.** Paste one address per line, review matches and unresolved entries, and frame the results together. Duplicate lines are skipped.
- **Make places recognizable.** Choose placemark colors, pin/circle/square/diamond shapes, icons, and notes. Search suggestions help find an address; selecting one zooms to a highlighted pin.
- **Work with KML projects.** Import KML and KMZ; create placemarks, paths, and polygons; export KML for other mapping tools.
- **Measure with precision.** Select distance, perimeter, and area units and decimal precision. Inspect coordinates, approximate elevation, and camera altitude.
- **Add context.** Search geographic layers, compare dated NASA satellite imagery, and position local image overlays with adjustable bounds, opacity, and rotation.
- **Capture a view.** Save map images and record silent map videos.
- **Connect a local AI client when you choose.** The optional MCP server exposes 13 tools for navigation, search, styled places, address-list jobs, layers, overlays, and video. It is off by default, loopback-only, and protected by a session token. Use the toolbar's Local MCP panel to copy current connection instructions; keep the token private.

## Map providers and requirements

Requires **macOS 14 or later**. Online maps, address lookup, and live data need internet access. The globe, Apple Maps, and OpenStreetMap do not require a Google key. Google Maps and Google photorealistic 3D need your own compatible key and enabled APIs; Google may charge separately. Your key is stored in macOS Keychain.

Provider coverage, search matches, 3D detail, and elevation accuracy vary. NASA history is a daily satellite archive, not historical street-level aerial imagery. Earth Pro is independently developed and is not affiliated with Google. Provider data and imagery remain subject to their own licenses and service terms.

No Earth Pro account is required. Projects and preferences are stored locally. Network requests go directly to the services used by the selected feature; see the [privacy policy](https://zachenson.com/earth-pro/privacy).

## Build and run

Install Xcode (with command-line tools). From this repository:

```sh
swift build
./script/build_and_run.sh --verify
```

The script creates a locally signed development app in `~/Library/Caches/EarthPro/BuildProducts/Earth Pro.app`. This is a development build, not a notarized distribution artifact.

For the Xcode application target, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then:

```sh
xcodegen generate
open EarthPro.xcodeproj
```

Select your own development team before signing. `project.yml` is authoritative. The included bundle identifier and export team settings identify the original project; change them for your own distribution.

Run the existing tests:

```sh
./script/test.sh
```

## License and credits

Original application source and original app artwork are licensed under the **MIT License**. See [LICENSE](LICENSE). Bundled datasets, terrain data, imagery, provider services, and third-party names are **not relicensed by MIT**. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), the resource attribution files, and each provider's terms.

Bug reports and focused contributions are welcome through GitHub issues and pull requests. Please omit API keys, MCP tokens, private addresses, and personal map files from reports.
