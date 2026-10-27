# Cyberdesk for Mac
A movable glass desktop workspace with per-monitor cards, real Desktop browsing, configurable shortcuts and music controls.

## Download
Get the [latest preview release](https://github.com/treytoscano-maker/cyberdesk/releases/tag/v3.7.0). Download `Cyberdesk-v3.7.0-AppleSilicon.zip` for an experimental prebuilt app on Apple Silicon Macs, or `Cyberdesk-v3.7.0-Starter.zip` for the source starter. Intel Macs must build from source; Intel is untested.

The prebuilt app is locally signed, not Apple Developer ID signed or notarized. macOS may block a downloaded copy. Building from reviewed source is the supported fallback; no security settings need to be disabled. This is an early preview, not a verified installer for every Mac.

### Personalize with the prompt
1. Open [Customize Cyberdesk Prompt.txt](Customize%20Cyberdesk%20Prompt.txt).
2. Paste it into your coding assistant with this repository or extracted source folder attached. Fill in your workflow, project paths, apps, AI tools and music choice. No API keys are needed.
3. Have the assistant produce a `config.json` using [the example](Source/config.example.json).
4. In Cyberdesk choose **CUSTOMIZE → Import workflow file**. Review the result; previous configuration is backed up automatically.
5. Use CARDS and ARRANGE on each screen to choose and position its cards.

## Build from source
Requires macOS and Apple's Xcode Command Line Tools (install from Apple). Tested locally on macOS 26; other versions and Macs are not yet verified. No paid AI API is required.

1. Run `Build Cyberdesk.command`. It builds outside cloud-synced folders and locally signs `~/Library/Caches/Cyberdesk/Build/Cyberdesk.app`.
2. Open the built app. A menu-bar item provides Show, Hide and Restore original desktop / Quit.
3. Choose CUSTOMIZE for your workspace name and music service. Open the workflow file for projects, apps, AI tools and links, or import JSON made with the included setup prompt. Missing apps show unavailable.
4. Choose CARDS separately on each monitor. ARRANGE moves/resizes cards. The bar is also movable. Single-monitor choices are separate.
5. FOLDERS → Desktop / Loose Files shows actual loose Desktop files. Screenshots & Images filters images. Add files or drop a file/image to COPY it onto Desktop without moving originals or overwriting names. New screenshots saved to Desktop appear automatically. Click an image tile for an in-app preview, previous/next navigation and drag-out of the original file. Drag a file tile or preview image into another app to attach the actual file; choose Arrange tiles for internal reordering. Right-click a tile to edit its Cyberdesk display name/group or reveal it in Finder. These labels never rename or move actual files.

Spotify and Apple Music can show real playback and controls after Connect and macOS approval. SoundCloud/custom URLs open their own player; native track metadata/transport is not provided for web services. Apple Music was checked against its installed scripting definition but not verified with a playing user library.

## Your own cards and organization
**CUSTOMIZE → Edit cards & shortcuts** edits the five shortcut sections and adds custom cards. Each shortcut takes a label, destination (URL, absolute/~ path, app name or `bundle:identifier`), and optional description. Add/remove shortcuts, rename cards, choose cyber red/cyan for custom cards, then Save cards. CARDS chooses which appear on each monitor; new custom cards start hidden and crowded layouts can reject additional cards. Removing a custom card removes only its definition. Configuration saves keep a backup.

Right-click a Desktop tile to set a display name or group. Empty fields restore automatic naming/grouping. The actual file/folder names and locations are unchanged. These labels are in the workflow configuration too, so an authorized local assistant can help organize the view.

Optional config fields: `customCards` (up to 20 `{id, title, color, shortcuts}` objects, with IDs beginning `custom-`), `cardTitles` (built-in section IDs to titles), `desktopLabels` and `desktopGroups` (exact existing Desktop filename to display label/group). Shortcut IDs remain unique across every card.

## Configuration
Local file: `~/Library/Application Support/Cyberdesk/config.json`. Example: `Source/config.example.json`. Saves from Customize/import keep earlier configuration copies in a sibling Backups folder. Manual edits reload automatically; invalid edits keep the last valid setup in the running app. Keep your own copy before editing manually. IDs must be unique letters/numbers/underscores/hyphens; avoid internal action names. Supported sections: projects, ai, creative, systems, links. Use a path (`~/Documents/My Project`), application name, bundleIdentifier, or supported URL. URL routes take precedence. AI entries launch tools; they do not call models, connect accounts or expose keys.

`CYBERDESK_CONFIG` can select a different config file when launching the executable. Layout preferences are stored locally under the app's bundle identifier. Don't ship your config, preferences, Desktop files, logs, or backups.

## Restore
Restore original desktop / Quit closes the overlay and disables its own optional sign-in startup. The app does not replace Finder or change your wallpaper. Enable sign-in only if wanted using the menu-bar option; desktop layers open on connected screens at sign-in. Keep your original app and configuration before upgrading. The main author's existing room backup is not included in this generic starter.

## Sharing
This package contains generic defaults, source, a generated city wallpaper, a reusable customization prompt, and an MIT license for the code. The wallpaper is AI-generated and may be replaced. App/service names belong to their respective owners; this project has no affiliation with them. No accounts, private configuration, client files, screenshots, or API keys are included. Review your own screenshots and configuration before posting. This public starter excludes the author’s personal setup.

## Verification
Local Swift build, file-copy/configuration checks, and interface regression checks passed. The checks cover duplicate-name safety, originals preserved, invalid image rejection, config backups, folder views and web/native music states. The file export pasteboard contains file URLs rather than text IDs, and automated checks cover preview state, custom cards and virtual labels. End-to-end dragging into chat and Apple Music playback still need hands-on acceptance. The experimental prebuilt download is Apple Silicon only and is not notarized.
