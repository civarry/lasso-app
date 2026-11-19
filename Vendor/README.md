# Vendored frameworks

**Sparkle.framework** (in-app updates): Sparkle 2.10.1, unmodified apart from removing
`XPCServices` (only sandboxed apps need them; Lasso isn't sandboxed). Taken from the official
release archive `Sparkle-2.10.1.tar.xz` (sha256 `1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`) at
https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1. License: `Sparkle-LICENSE` (MIT).

Vendored rather than added as a Swift package because resolving Sparkle's binary package could hang
the command-line build while Xcode held its download lock. To update: replace the framework from a
newer release archive, delete `Versions/B/XPCServices`, and update this note.
