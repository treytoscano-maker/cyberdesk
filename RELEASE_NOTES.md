# Cyberdesk 3.6.0 · early preview

Movable cyberpunk glass desktop cards, per-monitor layouts, real Desktop file browsing, configurable apps/projects/AI shortcuts, and a reusable workflow setup prompt.

Downloads:
- **Cyberdesk-v3.6.0-AppleSilicon.zip**: experimental arm64 app, prompt, example config and README.
- **Cyberdesk-v3.6.0-Starter.zip**: generic source and build script, prompt, example config and README.
- **Customize-Cyberdesk-Prompt.txt**: standalone setup prompt (use with the source starter/repository).

Start with the README. CUSTOMIZE → Import workflow file loads your personalized config and backs up the previous one. AI tool shortcuts launch apps; model selection stays inside those apps. Spotify and Apple Music have native integration; SoundCloud/custom music links open their web player.

Tested locally on macOS 26 / Apple Silicon. Swift build, copy/original-preservation checks, configuration backups, UI regression checks and native interface inspection passed. Apple Music playback and physical external drag-and-drop need hands-on acceptance. Other Macs/macOS versions and Intel builds are unverified.

The prebuilt app is locally signed, not Developer ID signed or notarized; macOS may block downloaded copies. Building from reviewed source is the supported fallback. Optional sign-in startup is off unless enabled in the menu. Restore original desktop / Quit closes the overlay and disables its startup. No private configuration, accounts, keys or client material are included.
