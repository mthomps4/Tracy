# Tools to install later (sudo / brew / package manager)

Running list of system-level dependencies Tracy v2 will want. None are required for the initial shell to work — most are for upgrades that benefit from sudo.

## Voice in / out

- [ ] `whisper-cpp` or `faster-whisper` — local STT, replacement for browser SpeechRecognition when latency / privacy matters. Browser STT works on phone Safari today.
  - Arch: `paru -S whisper.cpp` or compile from source.
- [ ] `piper` — local neural TTS for voice replies. Faster + better than browser TTS, runs on CPU.
  - Arch: `paru -S piper-tts-bin` (AUR).
- [ ] `ffmpeg` — audio capture + transcoding for any voice path.
  - Arch: `sudo pacman -S ffmpeg`.

## Notifications

- [ ] `ntfy` — push notifications to Matt's phone when Tracy finishes long-running work.
  - Arch: `sudo pacman -S ntfy-sh`; self-hostable.

## Document / artifact handling

- [ ] `tesseract` — OCR for screenshots + photos Matt drops into chat.
  - Arch: `sudo pacman -S tesseract tesseract-data-eng`.
- [ ] `pandoc` — convert between markdown / HTML / PDF / docx for artifact pipelines.
  - Arch: `sudo pacman -S pandoc-cli`.
- [ ] `imagemagick` (already installed — favicon work confirmed it) — image manipulation.

## Web / data ingest

- [ ] `yt-dlp` — for "summarize this YouTube video" use cases.
  - Arch: `sudo pacman -S yt-dlp`.

## Memory infrastructure (TBD on research)

Possible options pending research synthesis:
- [ ] `kuzu` (embedded graph DB) — if AGE proves limiting.
- [ ] `qdrant` (vector DB sidecar) — if pgvector at scale becomes a bottleneck.
- [ ] Local embedding model via `bumblebee` + `nx` (probably already-available via mix deps).

## File watching (engineering ergonomics)

- [ ] `watchman` — Tracy's dev server complained `sh: line 1: watchman: command not found` on boot. Speeds up Phoenix's file watcher.
  - Arch: `paru -S watchman-bin` (AUR).

## Network — eventual Caddy + Tailscale Funnel for public ingress

Deferred. v2 stays on Tailscale-private until Tracy needs to receive webhooks (GitHub / Linear / Slack).

---

I'll add to this list as I run into things. When you're back at the keyboard with sudo, you can install whatever's still useful at that point.
