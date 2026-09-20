<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Publishing

How Garuda is published, and what has to be true before a release is listed.
This is about distribution. For running a server in production -- system
packages, certificates, services -- see
[INSTALLATION.md](INSTALLATION.md#running-as-a-systemd-service).

## Swift Package Index

[swiftpackageindex.com](https://swiftpackageindex.com) is where Swift packages
are found. It reads the repository directly: there is nothing to upload and no
account to keep. It renders the README as the package page, so the README *is*
the listing.

### What it needs

| | |
|---|---|
| A public repository | [github.com/grepjava/garuda](https://github.com/grepjava/garuda) |
| A parseable `Package.swift` at the root | yes |
| At least one library product | `Garuda`, `GarudaUploads`, `GarudaJSON`, `GarudaSQL` |
| At least one semantic-version tag | `1.0.0` |
| A recognised licence | MIT, in `LICENSE` |

### Submitting

Open a pull request against
[SwiftPackageIndex/PackageList](https://github.com/SwiftPackageIndex/PackageList)
adding the repository to `packages.json`, or use the form at
[swiftpackageindex.com/add-a-package](https://swiftpackageindex.com/add-a-package),
which opens the same pull request. The list is sorted case-insensitively and
the URL is lowercased with a `.git` suffix:

```
https://github.com/grepjava/garuda.git
```

The index then polls the repository. **New tags appear on their own**; a
release is never submitted twice.

### `.spi.yml`

`.spi.yml` in the repository root asks the index to build and host DocC for
the four library targets. Garuda has about 5,400 documentation comments over
1,900 public declarations, so this is worth having. The executables are left
out: they are the benchmark application and the conformance server, not API
anyone imports.

Validate it against the current schema before relying on it -- the index's own
`spi-manifest` package can check the file, and a manifest it cannot parse is
ignored rather than reported.

### What the compatibility matrix will show, and why

The index builds every package across Swift versions and platforms and prints
a grid. **Garuda will not be green everywhere, and two of the gaps are
expected rather than faults.**

- **iOS, tvOS, watchOS, visionOS: will fail.** Garuda is a server. It forks
  worker processes, binds listening sockets and uses epoll or kqueue. It
  declares `platforms: [.macOS(.v15)]` and nothing else. These builds are
  attempted anyway and their failure is correct information.
- **macOS: expected to fail, and this one is fixable.** aviancore links
  `libssl` and `libcrypto` but declares no search path for them. On Linux the
  headers are where the compiler already looks. On macOS they are in
  Homebrew's prefix, which is why [INSTALLATION.md](INSTALLATION.md#macos)
  tells a developer to pass them by hand:

  ```bash
  swift build -Xcc -I"$(brew --prefix openssl@3)/include" \
              -Xlinker -L"$(brew --prefix openssl@3)/lib"
  ```

  The index's builders run a plain `swift build`. They cannot pass those
  flags, so the macOS build fails to find `openssl/ssl.h`.
- **Linux: expected to pass.** The official Swift container images carry
  `zlib1g-dev`, and `libssl-dev` arrives with the toolchain's own
  dependencies. This has not been verified against the index's builder image;
  the Linux CI job here is the closest evidence.

### Fixing the macOS build

The macOS failure is worth fixing, because it is not only the index's problem:
every macOS developer hits it, and the flags in INSTALLATION.md are a
workaround for a manifest that does not describe its own dependency.

The fix is a `systemLibrary` target in **aviancore** with a `pkgConfig` name,
which makes pkg-config supply the include and link paths on every platform:

```swift
.systemLibrary(
    name: "COpenSSL",
    pkgConfig: "openssl",
    providers: [.brew(["openssl@3"]), .apt(["libssl-dev"])]
)
```

`CAvian` then depends on it instead of naming `.linkedLibrary("ssl")` and
`.linkedLibrary("crypto")` directly.

**This would help a macOS developer. It probably will not turn the index's
macOS row green**, and the reason is worth knowing before anyone spends a day
on it. Homebrew's `openssl@3` is keg-only: its `.pc` files are not on
pkg-config's default search path, which is why CI sets

```yaml
PKG_CONFIG_PATH=$(brew --prefix openssl@3)/lib/pkgconfig
```

before building. The index's builders set no such variable, and there is no
reason to think they have Homebrew's OpenSSL installed at all. `pkgConfig`
finds a library that is discoverable; it does not install one.

Two other things to check:

- **`pkgConfig` must not introduce unsafe flags.** A package consumed by
  version is refused if any target sets them, and CI has a job that builds
  Garuda as a versioned dependency precisely to catch that. `pkgConfig` is not
  an unsafe flag, but the change should be proved against that job.
- **Where pkg-config is missing entirely**, the `providers` list is advice
  printed in an error, not an install.

The only change that would make the macOS row green unconditionally is for
aviancore to stop needing OpenSSL -- BoringSSL now covers the record layer and
the handshake, leaving `avian_crypto.c`, ACME and QUIC's primitives on
OpenSSL. That is a project, not a manifest edit, and it is not on the roadmap.

So the macOS row stays red, and the honest reading of the matrix is that this
is a Linux server package which builds on macOS with two flags. CI proves that
on every push.

### Is a Mac needed for any of this?

No, and nothing below needs one either.

- **Listing the package** needs no build anywhere. The index reads the
  repository and builds on its own machines; submission is a pull request
  against a JSON file.
- **macOS builds are already proved on every push.** CI runs the release build
  and the unit tests on a GitHub-hosted `macos-15` runner. Nobody here owns
  the Mac that does it.
- **A macOS fix could be written and verified the same way**, through CI,
  without local hardware.

A Mac would buy faster iteration on a macOS-only problem -- minutes instead of
a CI round trip -- and nothing else. There is one open macOS-only question it
would help with: four unit tests fail on macOS and nowhere else, three of
which pass when run serially, so they interfere through something the suites
share. CI keeps both runs to tell those apart, and that job does not fail the
build.

### Badges

Once the package is indexed, these render the Swift versions and platforms the
index measured, and they update themselves:

```markdown
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fgrepjava%2Fgaruda%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/grepjava/garuda)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fgrepjava%2Fgaruda%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/grepjava/garuda)
```

They are deliberately not in the README yet: a badge added before the first
build reports nothing, and a platforms badge is worth adding only once the
matrix says what it should.

### Repository metadata

The index shows GitHub's own description and topics, so they are part of the
listing rather than decoration. Keep the description matching the README's
opening line, and the topics on what someone would search for.

## Checklist for a release

Tagging is what publishes. Before a tag:

1. Run everything under "Before cutting a version" in
   [RELEASE.md](RELEASE.md) against
   a release build.
2. Move the `Unreleased` section to the new version with its date.
3. Check the version policy in [COMPATIBILITY.md](COMPATIBILITY.md): a
   breaking change to anything covered needs a major version.
4. Confirm the aviancore dependency names a released tag, not a branch or a
   local path, and that a clean checkout resolves it.
5. Tag and push. The index picks the tag up on its own.
