# Building Lasso from source

Building it yourself gives you a copy that macOS doesn't quarantine, so there's no "can't verify the
developer" step, and nothing depends on someone else's signing certificate.

## What you need

- An Apple Silicon Mac on **macOS 26** or later
- **Xcode 26** or later (from the App Store)
- [Homebrew](https://brew.sh), for XcodeGen

No Apple developer account is needed.

## Build and run

```sh
git clone https://github.com/civarry/lasso-app.git
cd lasso-app

# The Xcode project is generated from project.yml.
brew install xcodegen
xcodegen generate

# One-time: the MLX packages compile Metal shaders and need Apple's Metal toolchain (~700 MB).
xcodebuild -downloadComponent MetalToolchain
```

Then either:

- **In Xcode:** `open Lasso.xcodeproj`, pick the **Lasso** scheme and press **⌘R**.
- **From the terminal:**

  ```sh
  xcodebuild -scheme Lasso -configuration Release -derivedDataPath .build build
  cp -R .build/Build/Products/Release/Lasso.app /Applications/
  open /Applications/Lasso.app
  ```

The first build takes several minutes while the Swift packages (MLX in particular) compile.

## First launch

Lasso lives in the menu bar. On first launch it asks for **Screen Recording** permission: turn it on
in System Settings → Privacy & Security → Screen Recording, then quit and reopen Lasso. The capture
shortcut is **⌃⇧C** (change it in Settings). Voice input in chat asks for microphone access the first
time you use it.

## Code signing

By default the build is signed **to run locally** (ad-hoc), so it works without any Apple account.
The catch: macOS ties permissions to the signature, and an ad-hoc signature changes with every
build, so after you rebuild, macOS asks for Screen Recording again (if it doesn't take effect, remove
Lasso from the Screen Recording list and add it back).

To keep permissions across rebuilds, sign with a free Apple Development certificate:

1. In Xcode → Settings → Accounts, add your Apple ID, select your team and click **Manage
   Certificates… → + → Apple Development**.
2. Find the certificate's hash:

   ```sh
   security find-identity -v -p codesigning
   ```

   Copy the 40-character hex string in front of `"Apple Development: …"`.
3. Create `Config/Signing.local.xcconfig` (it's git-ignored) with:

   ```
   CODE_SIGN_IDENTITY = <the 40-character hash>
   ```

4. Run `xcodegen generate` again and rebuild.

## Tests

```sh
xcodebuild -scheme Lasso -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/lasso-dd test
```

A few suites call real models or services and are skipped unless you opt in (for example
`TEST_RUNNER_LASSO_LIVE=1`); see the comment at the top of each `*LiveTests.swift` file.

## Troubleshooting

- **`missing Metal Toolchain`** during the build: run `xcodebuild -downloadComponent MetalToolchain`.
- **The capture shows only your wallpaper or nothing:** Screen Recording isn't granted to this build.
  Remove Lasso from the list in Privacy & Security, add it again, and reopen Lasso.
- **`Lasso.xcodeproj` is missing or out of date:** run `xcodegen generate`. The project file isn't
  committed; `project.yml` is the source of truth.

## License

Lasso is licensed under the [Apache License 2.0](LICENSE). Redistributions, including modified
versions, must keep the [NOTICE](NOTICE) file that credits the original author.
