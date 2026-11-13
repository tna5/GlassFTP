# Contributing to GlassFTP

Thanks for helping! GlassFTP is a native macOS SFTP client written in Swift
(SwiftUI + AppKit), built with SwiftPM and the Command Line Tools — no Xcode
project.

## Getting started

```
make debug   # build, bundle and launch a debug build
make test    # run the self-test suite (release build)
```

Requires macOS 26 and Swift 6. The source layout is described in the
[README](README.md#layout).

## Pull requests

- Keep each pull request focused on one change.
- Run `make test` before opening it; all checks must pass.
- Match the Finder's behaviour when in doubt — that is the reference for every
  interaction.
- Describe how you tested the change (which server, which views).

## Reporting bugs

Open an issue with the bug report template: your macOS version, the server
(OpenSSH version if known), the steps to reproduce, and what you expected.
