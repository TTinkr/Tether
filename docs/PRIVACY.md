# Privacy and network behavior

No account or built-in analytics. Tokens does not send speech audio or transcripts to a remote transcription service. There is no Terms step: first run goes straight to the Accessibility step, and nothing is asked of macOS until you press one of that step's buttons.

## What leaves this Mac

Speech processing is local in the supplied engines. Optional formatting sends transcript excerpts to Ollama on `127.0.0.1:11434`; the transport disables system proxies and rejects HTTP redirects. Model discovery excludes remote models. The already-running Ollama service is a separate program that you control: loopback transport is not proof of that program's logging or outbound behavior. Use trusted local models and disable Ollama cloud features if you require offline inference.

Tokens pastes your words into the app you chose and can press Return when Auto-send is enabled and delivery is verified. That destination app may upload, save or share the text under its own settings. Local speech recognition does not make a cloud chat or website local.

Local does not mean no network activity:

- SwiftPM fetches dependencies during builds.
- Speech models download from their pinned HTTPS origins (Hugging Face) and are checked against a SHA-256 before use. The selected local model (Parakeet v3 by default in community packages, about 740 MB) starts downloading automatically at launch if needed, including before setup finishes. Other model downloads are selected on the Models page. An explicit Apple selection starts no local-model download. Capture waits for a selected local model to verify; it does not use Apple as a download fallback. The download service and its content-delivery providers see ordinary network metadata such as your IP address and requested model, not speech audio or transcripts.
- macOS may download its own speech assets for Apple speech.
- Update checks run only in builds configured with an update feed (community preview builds have none). A configured update server sees an ordinary request for the feed, including your IP address and the app version.
- Documentation links open in your browser.

## What is stored on this Mac

These records live under your macOS user account. History and recovery are readable text; the app does not add its own encryption. New files and repair backups use owner-only POSIX permissions (`0600`) inside an owner-only data directory (`0700`). Existing history/recovery permissions are tightened on read without adding owner access that was deliberately removed. Successful atomic rewrites create new private files. This does not isolate them from other programs running as your user, administrators, filesystem ACLs, backups or disk access; disk protection and your account still matter:

| What | Where | Cleared by |
|---|---|---|
| Dictation history (your words, timestamps, target app) | `~/Library/Application Support/<bundle id>/prompt-history.json` | History → Clear History |
| Recovery journal (recognized words kept until delivery is confirmed, so a failed paste can be recovered) | `recognized-transcript-recovery.json` beside the history | Clear History, except the items below |
| Repair backups of an unreadable history file | `prompt-history.preserved-<time>-<id>.json` beside the history | **Not** cleared by Clear History; delete them by hand |
| Diagnostic log | `~/Library/Logs/<bundle id>/events.log` and `events.1.log` | **Not** cleared by Clear History; delete the folder by hand |
| Settings, dictionary words, setup state | the app's preferences (`defaults`) | Removing the app's preferences |
| Downloaded speech models | `~/Library/Application Support/<bundle id>/` | The Models page, or by hand |

Clear History deliberately keeps two things: the words of a dictation still in progress, and words held from a paste that failed in the current run (so they can still be copied). A recovery entry written in the same second as the clear may also survive. If the history file cannot be read, Clear History deletes nothing and says so.

The diagnostic log records event names, timestamps, counts, durations, the destination app's bundle identifier and the shape of a delivery (for example, letters and digits masked). Its callers are written to omit transcript text, audio and secrets, but the log is not an audited redaction boundary. It rotates at 16 MB, keeping one older file. Log files and their directory use owner-only POSIX permissions; existing permissions are tightened without adding owner access that was deliberately removed.

Pasting temporarily places dictated text on the macOS clipboard. Tokens asks clipboard-history tools to skip automatic paste writes using transient markers and restores the previous clipboard after a confirmed paste if no newer copy has replaced it. If a paste cannot be confirmed, the dictated text can remain on the clipboard for recovery. These markers are a convention, not access control: other applications can read clipboard contents, and explicit Copy actions use the ordinary clipboard. Clear History does not clear the clipboard, copies in destination apps, or system backups.

The optional menu switch **Note On-Screen File When Mentioned** is off by default. When enabled, it reads up to five on-screen applications' focused window titles through Accessibility into temporary memory during a talk. Titles are not logged. The current public delivery path does not append the sampler's generated note. Turn the switch off to avoid that collection entirely.

Ordinary builds save no audio. Do not attach real transcripts, recordings, logs, private paths or credentials to bug reports.

## Permissions

Microphone, Speech Recognition and Accessibility stay under macOS control. Background listening is off by default and requires explicit consent. Mutating microphone and paste QA commands require developer-build metadata; ordinary community packages do not enable them. Synthetic preview/render command-line routes remain in the source and application. Dictionary previews can show the local personal dictionary, so preview output should also be treated as private unless it uses a fictional fixture.

This document describes the source configuration. It is not a packet-capture audit or an independent privacy certification.
