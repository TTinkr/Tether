# Security reports

Do not post exploitable details, credentials, real transcripts or recordings in public issues. Use GitHub private vulnerability reporting if enabled for this repository, or contact the project's public support address, contact@keeptinkr.ing, to arrange private disclosure.

Include version/commit, operating system, reproduction using fictional data, impact and a minimal suggested fix if known. No response-time or support-lifetime guarantee is implied.

Community builds do not inherit the security review, signing identity or notarization of official downloads. Developer-only QA routes must remain off in normal packages.

## Known optional dependency limitation

The pinned Orukeet SDK includes SentencePiece 0.2.0, affected by [CVE-2026-1260](https://github.com/advisories/GHSA-38vq-g6vr-w8wf). It is absent from the default Parakeet community build, which uses the separately pinned transcribe.cpp runtime. Orukeet models are hash-pinned, but an Orukeet-enabled distribution is blocked until a patched SDK is pinned and verified. See [BUILDING](docs/BUILDING.md) for the local-preview scope. Do not describe this tree as having no known vulnerable dependencies.
