# Whirr — outstanding productization

Code-side audit items from the original 2026-06-04 review are done. What's
left is mostly distribution work. None of this blocks day-to-day use; it
blocks **shipping to strangers without friction**.

## Activate Sparkle auto-update

The framework is embedded and the SwiftUI plumbing is wired (see
`UpdaterController.swift`, the `SUFeedURL` / `SUPublicEDKey` keys in
`Sources/Whirr/Resources/Info.plist`, and the "Auto-update (Sparkle)"
section in `README.md`). What's still needed:

- [ ] **Pick a host for `appcast.xml`.** GitHub Pages, S3, or your own
      domain. Cheap-and-easy: a GitHub Pages site on whatever public repo
      you decide to push Whirr to.
- [ ] **Generate the EdDSA signing keypair.** Run `generate_keys` from
      Sparkle's release artifact (the `Sparkle-for-Swift-Package-Manager`
      zip SPM already pulled into `.build/artifacts/sparkle/Sparkle/bin/`).
      Stores private key in your macOS Keychain (item:
      `https://sparkle-project.org`); prints the public key.
- [ ] **Wire the real values into Info.plist.** Replace
      `https://YOUR_DOMAIN/whirr/appcast.xml` with the real URL, and
      `YOUR_BASE64_PUBLIC_KEY_HERE` with the public key from the previous
      step. Commit.
- [ ] **First release**: zip the bundle (`ditto -c -k --sequesterRsrc
      --keepParent dist/Whirr.app dist/Whirr.zip`), run `sign_update
      dist/Whirr.zip` to get the EdDSA signature + length, upload the zip
      to the host, and create `appcast.xml` with a single `<item>`
      entry. The Settings → About row will switch from "not yet
      configured" to a real "Check for Updates…" button.

## Apple Developer ID + notarization

Without this, even Sparkle-delivered updates hit Gatekeeper's "Apple
cannot check for malicious software" wall on first launch — Sparkle's
EdDSA signature proves the update came from you, but Gatekeeper's
separate Dev ID check is what tells macOS to trust you in the first
place.

- [ ] **Apple Developer Program** ($99/yr).
- [ ] **Generate Developer ID Application cert** in Apple Developer
      portal; install into Keychain.
- [ ] **Swap `--sign -` for `--sign "Developer ID Application: …"`** in
      `build.sh` (one-line change).
- [ ] **Notarize after each release build**:
  ```sh
  ditto -c -k --sequesterRsrc --keepParent dist/Whirr.app dist/Whirr.zip
  xcrun notarytool submit dist/Whirr.zip \
      --keychain-profile "AC_NOTARY" --wait
  xcrun stapler staple dist/Whirr.app
  ```
- [ ] After Dev ID lands, **`SMAppService.daemon` will start actually
      launching the bundled daemon** (the current ad-hoc signing is why
      the menu shows "Advanced sampling unavailable"). Update
      `DaemonStatusRow`'s `.notFound` copy to drop the ad-hoc reference.

## Stretch (low priority)

- [ ] **Per-container Docker history graph.** Current Docker section is
      instantaneous-only; trend strip would match the system view's.
- [ ] **JSON-configurable rules / per-rule mute.** Externalize
      `RulesEngine.allRules` so power users can tweak thresholds without
      recompiling. 1-2 day refactor.
