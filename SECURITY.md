# Security reports

Do not post exploitable details, credentials, real transcripts or recordings in public issues. Use GitHub private vulnerability reporting if enabled for this repository, or contact the project's public support address, contact@keeptinkr.ing, to arrange private disclosure.

Include version/commit, operating system, reproduction using fictional data, impact and a minimal suggested fix if known. No response-time or support-lifetime guarantee is implied.

Community builds do not inherit the security review, signing identity or notarization of official downloads. Developer-only QA routes must remain off in normal packages.

## Known optional dependency limitation

The prior Orukeet SDK included SentencePiece 0.2.0, affected by [CVE-2026-1260](https://github.com/advisories/GHSA-38vq-g6vr-w8wf). This candidate pins a local rebuild using SentencePiece 0.2.2. Orukeet-enabled distribution remains blocked pending independent qualification of the rebuilt SDK. The default Parakeet community build uses the separately pinned transcribe.cpp runtime and does not include this SDK. See [BUILDING](docs/BUILDING.md) for the local-preview scope.
