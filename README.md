# UO Outlands AppImage

A Linux AppImage for [UO Outlands](https://uooutlands.com), a free Ultima Online shard.\
On first run it downloads GE Proton and the official Outlands launcher and keeps everything in one self-contained directory.

No manual Wine setup, no scattered files, just run the AppImage and play.

[![Donate](https://img.buymeacoffee.com/button-api/?text=Donate%20&emoji=%F0%9F%91%BE&slug=hezkore&button_colour=FFDD00&font_colour=000000&font_family=Inter&outline_colour=000000&coffee_colour=ffffff)](https://www.buymeacoffee.com/hezkore)

## Why

Outlands is a Windows game client.\
Getting it running on Linux normally means installing a specific Wine or Proton version yourself, pointing it at the launcher, and figuring out the right overrides.

This AppImage handles all of that so you can go from zero to playing with one file.

## How

On first run the AppImage checks that the machine is x86_64, that the data directory is writable, and that enough disk space is available. It then downloads GE Proton and the official Outlands launcher, verifies both files, sets up a dedicated compatdata directory, applies the needed Wine override, and starts the launcher.

Later runs go straight to launch using the same data directory.

The default data directory is `~/.local/share/uooutlands/`\
To use a different location, set `UOOUTLANDS_DATA_DIR` before launch:

```bash
UOOUTLANDS_DATA_DIR=/path/to/uooutlands ./UO-Outlands-x86_64.AppImage
```

## Install

Download the latest `UO-Outlands-x86_64.AppImage` from [Releases](https://github.com/Hezkore/uo-outlands-appimage/releases/latest).

<details open>
<summary>Automatic</summary>
<br>

Use [AppImage Installer](https://github.com/Hezkore/appimage-installer) to install, integrate, and keep the AppImage updated.\
It handles the desktop entry, icon, and future updates automatically.

</details>

<details>
<summary>Manual</summary>
<br>

Make the AppImage executable and run it:

```bash
chmod +x UO-Outlands-x86_64.AppImage
./UO-Outlands-x86_64.AppImage
```

To make the game appear in your application menu, create `~/.local/share/applications/uooutlands.desktop`, replacing the path with wherever you placed the AppImage:

```ini
[Desktop Entry]
Type=Application
Name=UO Outlands
Exec=/path/to/UO-Outlands-x86_64.AppImage
Icon=uooutlands
Categories=Game;
```

To update, download the new AppImage from [Releases](https://github.com/Hezkore/uo-outlands-appimage/releases/latest) and replace the old file. The desktop entry does not need to change as long as the path stays the same.

Without [AppImage Installer](https://github.com/Hezkore/appimage-installer) there are no automatic update checks, the icon will not appear in the launcher unless your desktop environment picks it up on its own, and you manage the file and desktop entry yourself.

</details>

## Building

Clone the repository and run the build script:

```bash
git clone https://github.com/Hezkore/uo-outlands-appimage.git
cd uo-outlands-appimage
./build.sh
```

The host system needs `tar`. The build uses the bundled `zenity` runtime when possible and falls back to terminal output when no GUI dialog can be shown.

## Disclaimer

This project is not affiliated with, endorsed by, or associated with Ultima Online or the UO Outlands private server in any way.
