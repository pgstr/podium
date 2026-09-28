# Releasing Podium for macOS

> [!NOTE]
> This workflow requires an Apple Developer subscription, a Developer ID
> certificate, and notarization credentials. Until official signed releases
> exist, local ad-hoc builds and the localhost-SSH LaunchAgent are the
> supported path.

Podium's everyday `make build` remains ad-hoc signed for local development.
Distribution builds require an Apple **Developer ID Application** certificate,
the hardened runtime, a secure timestamp, and Apple notarization.

## One-time setup

1. Install a Developer ID Application certificate and its private key in the
   signing keychain.
2. Store notarization credentials in the Keychain:

   ```sh
   make notary-setup NOTARY_PROFILE=podium-notary
   ```

   `notarytool` prompts for Apple ID/team/app-password or App Store Connect API
   credentials. No credentials are written to the repository.

## Build, sign, test, and notarize

```sh
make release \
  SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
  NOTARY_PROFILE=podium-notary \
  VERSION=0.1.0
```

The target runs the full test suite, builds an arm64 release executable, signs
it with the virtualization entitlement and hardened runtime, submits
`dist/podium-<version>-macos-arm64.zip`, waits for Apple's decision, and asks
Gatekeeper to assess the signed executable. A failed test, signature check,
upload, or assessment stops the release.

Raw command-line executables do not provide an app/DMG/package container to
which `stapler` can attach a ticket. Apple publishes the accepted ticket for
Gatekeeper; a future installer package or disk image should itself be notarized
and stapled before distribution.

Apple references:

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

## Direct launchd migration

Once a Developer ID identity is installed, replace the localhost-SSH
LaunchAgent with the direct template:

```sh
make install-direct \
  STACK=examples/stack.json \
  SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)"
```

This rebuilds and installs the signed executable, verifies its signature
authority, boots the direct LaunchAgent, and removes Podium's dependency on
Remote Login. Keep the old loopback SSH key until the direct agent has survived
a reboot; it can then be removed from `~/.ssh/authorized_keys` together with
`~/.ssh/podium_localhost*`, and Remote Login can be disabled if nothing else
uses it.
