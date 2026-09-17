# FreshApple

A small SwiftUI app for renewing and reinstalling your own iOS apps, using SideSign and minimuxer. LocalDevVPN is a separate prerequisite. Requires iOS 18.4+ and Xcode 16.3+; use an Apple Silicon simulator (the upstream device binaries do not support Intel simulators).

## Run

Open `../FreshApple.xcodeproj`, select FreshApple, and run on your iPhone with your development team. Swift Package Manager downloads the pinned signing dependencies and device binaries. The simulator supports the interface and IPA storage; device installation requires an actual iPhone.

1. Bootstrap FreshApple using Xcode or your existing sideloading tool. Enable Developer Mode and trust your Mac.
2. Export a lockdown pairing record for **this iPhone** with your existing pairing tool. Import the `.mobiledevicepairing` or `.plist` file in Setup. Pairing secrets are stored in the device-local Keychain.
3. Install and connect LocalDevVPN. Use **Test LocalDevVPN connection** to validate the actual lockdown connection.
4. Enter your Apple Account and an HTTPS anisette server you operate or trust. Choose trusted-device, SMS, or voice verification, complete two-factor authentication, and select your developer team. FreshApple saves the session, not your password.
5. Import your source IPAs using **+**, including FreshApple’s own exported IPA if you want self-refresh. Use the same team and bundle IDs as the installed apps.
6. Tap **Refresh Apps**. Signing material is reused, profiles are renewed, and installation_proxy installs updates without uninstalling apps.

Self-refresh runs last. FreshApple persists a pending result before its executable is replaced and verifies the embedded profile’s exact UUID the next time it launches. Matching expiration dates alone do not count as success. Importing an IPA alone never claims it is installed or gives it a fabricated expiration date.

Long-press the status ring, or tap **View diagnostics**, for pairing, connection, team, certificate, profile, and activity information. Apple authentication, profile generation, and physical-device install still require end-to-end verification with your account and device. No account credentials are included in the project.

## Optional build manifest

Setup accepts an HTTPS manifest. Only apps already imported by the user are updated. Downloads must match the bundle identifier, version, and checksum. Older versions are skipped; identical versions and hashes use the cached IPA.

```json
{
  "apps": [{
    "bundleID": "com.example.myapp",
    "version": "1.4",
    "ipa": "https://your-host.example/myapp.ipa",
    "sha256": "REPLACE_WITH_64_HEX_CHARACTERS_FROM_SHASUM_A_256"
  }]
}
```

Generate the checksum with `shasum -a 256 myapp.ipa`. Publish the IPA first, then atomically replace the manifest. This initial version supports directly accessible HTTPS URLs; it does not implement GitHub login or custom download authorization headers.

## Automation

The **Refresh Apps** App Intent is exposed to Shortcuts and opens FreshApple. Put your LocalDevVPN action before it. Background processing is requested after three days and remains subject to iOS scheduling. Reopening the app preserves the planned date instead of postponing it; failed background attempts retry after six hours. Enable reminders in Setup to schedule a notification 48 hours before each confirmed expiration. Neither a background task nor a Shortcut guarantees uninterrupted self-installation.

## Data and behavior

- `Application Support/FreshApple/registry.json`: atomic JSON registry, with relative IPA filenames.
- `Application Support/FreshApple/Apps/`: cached originals, validated using SHA-256 before signing.
- Keychain: session, team, signing certificate/private key, anisette provisioning state, pairing record; `AfterFirstUnlockThisDeviceOnly`, no iCloud sync.
- Temporary signing directories are removed after each app. During self-refresh, the bundle is uploaded to AFC staging before local cleanup.
- Refresh operations are serialized across the button, Shortcut, and background task. Completed app results survive a later app’s failure.
- No uninstall, certificate revocation, or bundle-ID rewriting is performed. Missing profile capabilities or a different signing team stop installation. Archives containing traversal paths, symlinks, multiple main apps, or more than 4 GB expanded data are rejected.
- Source IPAs are not automatically discovered from installed apps. Free-team app and capability limits are enforced by Apple’s services.

## Dependencies

- [SideSign](https://github.com/SideStore/SideSign), pinned to `df2b8e4257454f0c7629276d409d6e9d7953fdf6` (GPL-3.0 per upstream).
- [minimuxer](https://github.com/SideStore/minimuxer), vendored at `20248550bbe014805460d4fa22ea69f146d338a0` (AGPL-3.0; license included). Its nested local Swift packages require local integration. FreshApple removes the unused libimobiledevice backend from the package graph to avoid colliding C symbols; the idevice backend is retained.
- Transitive package versions are recorded in `Package.resolved`. Upstream prebuilt binaries can emit newer-deployment-target linker warnings on Xcode 16.3; test on your target iOS version before relying on unattended refreshes.

Retain upstream licenses and source obligations when distributing builds. The app does not bundle LocalDevVPN.
