# Remodex build automation

GitHub Actions build tooling for the [Remodex](https://github.com/Emanuele-web04/remodex)
iPhone application. It validates an immutable source revision and produces an
unsigned device IPA. Xcode tests are compiled but never executed.

The archive-only mode runs the current Swift recovery regression, compiles the
device app and widget, and inspects the resulting IPA. Its manifest records that
validation scope separately from the full workflow.

Application sources are checked out with a repository-scoped, read-only deploy
key. Build output and diagnostics are encrypted to the supplied public
certificate before artifact upload. The private decryption key is not stored in
this repository or provided to Actions.

Only manual workflow dispatch is enabled. No source credentials or unencrypted
application artifacts are published by this workflow.
