# App Store Connect remaining (lilC 0.1.0)

In-repo. Does not replace App Store Connect. Use this while uploading the first build.

## Already in the binary / repo

- Bundle display name: lilC
- Version: 0.1.0
- Encryption: `ITSAppUsesNonExemptEncryption = false`
- Privacy and Terms HTTPS:
  - https://garrettmichae1.github.io/lilc/privacy.html
  - https://garrettmichae1.github.io/lilc/terms.html
- Support: mailto:support@lilc.app
- No account. C stays free. Optional Linux course IAP (`lilc.linux.course`) when shown. Agent UI hidden
- PicoC is an interpreter, not GCC — keep that wording in the description

## Connect-only (cannot finish from git)

1. Sign in at https://appstoreconnect.apple.com with the Apple Developer account.
2. Create the iOS app if it does not exist. Bundle ID in the project is `lilC` — confirm it matches the App ID in the developer portal (reverse-DNS such as `app.lilc` is typical if you still need to register one).
3. Upload a Release build from Xcode (Organizer → Distribute) or `xcodebuild -scheme lilC -configuration Release`.
4. Age rating questionnaire.
5. App Privacy nutrition labels (data not collected).
6. Screenshots. Minimum for iPhone:
   - 6.7" (iPhone 16 Pro Max / 17 Pro Max class): home, editor + hello world output, syntax error / jump-to-error, Settings Light, Settings Dark
   - 6.1" (iPhone 16 / 17 class): the same five frames
   - Optional iPad if the record includes iPad
7. Description, subtitle, keywords. Honest only: free C learner, PicoC, not GCC, no AI in this release.
8. Support URL: https://garrettmichae1.github.io/lilc/
9. Marketing URL (optional): https://garrettmichae1.github.io/lilc/web/
10. Review notes: no demo account. Open editor → RUN on the starter `hello.c`. Agent is hidden. There is no C Manual and no remote VM.
11. Attach IAP `lilc.linux.course` (non-consumable, $2.99) to this version. Paid Apps agreement must be Active. Xcode Run uses `lilC/Resources/Products.storekit` (local StoreKit). TestFlight / a device with StoreKit Configuration set to None uses App Store Connect. Sandbox Apple ID for device tests.

## Screenshot checklist

- [ ] Home (Light)
- [ ] Home (Dark)
- [ ] Editor with hello world output
- [ ] Friendly syntax error + ERROR jump
- [ ] Settings PicoC note + legal links
- [ ] Caption text does not say GCC, compiler toolchain, AI, or Linux VM

## Python workspace in the next update

The next build embeds CPython 3.14.7. Home's language picker switches separate C/Python project storage; Python runs locally in the editor with editable source and console input/output. No executable dependencies are downloaded. Packaging and runtime limitations are documented in [PYTHON_RUNTIME.md](PYTHON_RUNTIME.md). Before submitting, validate the signed archive in Organizer and verify Python input/Stop/imports on a physical iPhone. Update App Store descriptions and review notes for the new workspace; this local implementation does not publish an update.

JavaScript and Lua are also available in the next local build. JavaScript uses Apple's JavaScriptCore through public APIs; Lua 5.5.1 is built from vendored C sources with the iOS configuration. Both are local console environments with source editing and independent project storage. See [JAVASCRIPT_LUA.md](JAVASCRIPT_LUA.md) for the exact exposed APIs and cancellation limits.
