# Seafile iOS SwiftUI

An independent, unofficial SwiftUI rewrite of the Seafile iOS client.

This repository is not an official Seafile release and is not affiliated with or
endorsed by Seafile Ltd. The original Objective-C client and this rewrite are
distributed under the Apache License 2.0.

## Original project

- Project: Seafile iOS client
- Upstream repository: <https://github.com/haiwen/seafile-iOS>
- Upstream license: Apache License 2.0

The SwiftUI implementation in `SeafileSwift/` is based on the behavior and
feature set of the upstream client. Original copyright notices and license
terms remain applicable. See [LICENSE](LICENSE) for the full license text.

## Repository status

This repository contains source code, the Xcode project, app resources, and the
minimum project configuration needed to build the app. Build outputs, IPAs,
logs, caches, local signing configuration, and other non-code artifacts are not
committed.

No GitHub Release or prebuilt IPA is published from this repository.

## Requirements

- Xcode 26 or later
- iOS 26 SDK and deployment target
- An iOS 26 simulator, or an iPhone/iPad with a valid development signing setup
- No CocoaPods or third-party package installation is required by this project

## Build

Clone the repository:

```bash
git clone git@github.com:WuBarlynn/Seafile-iOS-Swift.git
cd Seafile-iOS-Swift
```

Open the Xcode project:

```bash
open SeafileSwift/SeafileSwift.xcodeproj
```

Select the `SeafileSwift` scheme and run on an iOS 26 simulator.

### Command-line simulator build

```bash
xcodebuild \
  -project SeafileSwift/SeafileSwift.xcodeproj \
  -scheme SeafileSwift \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

The generated app is under:

```text
~/Library/Developer/Xcode/DerivedData/SeafileSwift-*/Build/Products/Debug-iphonesimulator/SeafileSwift.app
```

### Device build and manual signing

Open the project in Xcode, select the `SeafileSwift` target, and configure:

1. **Signing & Capabilities**: select your development team.
2. **Bundle Identifier**: use an identifier registered for your signing profile.
3. Connect a device and run the `SeafileSwift` scheme.

For an unsigned Release build:

```bash
xcodebuild \
  -project SeafileSwift/SeafileSwift.xcodeproj \
  -scheme SeafileSwift \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build-device \
  CODE_SIGNING_ALLOWED=NO \
  build
```

To create an unsigned IPA manually:

```bash
mkdir -p Payload
cp -R build-device/Build/Products/Release-iphoneos/SeafileSwift.app Payload/
zip -qry SeafileSwift-unsigned.ipa Payload
```

Sign the resulting app/IPA with your own provisioning profile before installing
it on a device. Do not commit generated `.app`, `.ipa`, or signing files.

## Implemented areas

The rewrite includes account and SSO login, multi-account switching, library
browsing, copy/move/delete, previews, Markdown/Python editing, SeaDoc editing
and comments, online Office, Wiki, search, starred items, activities, settings,
local encrypted-library decryption, camera/photo upload, photo backup,
offline downloads, transfer management, and client-certificate authentication.

Some upstream features and extensions are still in progress; check the source
and commit history for the current state.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

All Seafile names, trademarks, and original project materials belong to their
respective owners. This repository is an independent rewrite and does not claim
official status.
