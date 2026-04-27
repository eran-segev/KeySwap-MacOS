# KeySwap Installation Guide

## System Requirements
- macOS 13.0 or later
- Apple Silicon (ARM64) or Intel Mac support
- Accessibility permissions enabled

## Installation Methods

### Method 1: DMG Installer (Recommended)
1. Download `KeySwap-1.2.0.0.dmg`
2. Double-click to mount the disk image
3. Drag the KeySwap.app to your Applications folder
4. Eject the disk image
5. Open Applications and launch KeySwap

### Method 2: ZIP Archive
1. Download `KeySwap-1.2.0.0.zip`
2. Extract the archive
3. Drag KeySwap.app to your Applications folder

### Method 3: Direct from Build
1. Open the project: `KeySwap.xcodeproj`
2. Select the KeySwap target
3. Build for Release: `Product > Build`
4. Find the app in `Derived Data` or build output directory

## First Launch Setup

When you first launch KeySwap:

1. **Grant Accessibility Permissions**
   - macOS will prompt you to allow KeySwap to use accessibility features
   - Open System Settings > Privacy & Security > Accessibility
   - Add KeySwap to the allowed apps list if prompted

2. **Test the Feature**
   - Open any application that accepts text input
   - Type in Hebrew layout, then press your configured hotkey (default: `F9`) to swap with English characters
   - Or type in English layout and press the hotkey to swap with Hebrew characters

## Usage

### Basic Operation

- **Hotkey**: Press your configured swap key (default: `F9`) to swap the last typed word
- **Raw swap**: Hold `Shift` while pressing the hotkey to swap without spell-check corrections
- **Revert**: Press `Ctrl+hotkey` to undo the last spell-check corrections (keeps the layout swap)
- **Active Layouts**: Hebrew and English keyboard layouts
- **Fallback Mechanism**: If Accessibility API is unavailable, a clipboard-based fallback is used

### Features

- Bilingual Hebrew/English character correction
- Configurable hotkey — choose from F1–F6, F9, or F10 in Preferences
- Per-language autocorrect toggles (English and Hebrew, both on by default)
- Post-swap spell checking with visible corrections HUD
- Hebrew spell check using the macOS Hebrew dictionary
- Error toast with the reason when a swap fails
- Distinct sound cues: clean swaps play "Tink", corrected swaps play "Pop"
- Accessibility-based text integration with clipboard fallback

### Preferences

Open the Preferences window from the KeySwap menu bar icon to:

- Change the swap hotkey
- Toggle autocorrect per language
- Adjust sound volume or mute sounds entirely
- Set error notifications to silent mode

## Troubleshooting

### "Accessibility permissions denied"

- Open System Settings > Privacy & Security > Accessibility
- Ensure KeySwap has permission

### "Hotkey doesn't work"

- Check that your configured key is not bound to another application
- Open Preferences to change the hotkey if there is a conflict
- Verify that KeySwap is running (check Activity Monitor)
- Quit and relaunch KeySwap

### "Characters not swapping"
- Ensure the correct keyboard layouts are installed (Hebrew/English)
- Check that you're using supported keyboard layouts

## Uninstallation

Simply drag KeySwap.app from Applications to Trash.

## Support

For issues or feature requests, visit: https://github.com/eran-segev/KeySwap-MacOS
