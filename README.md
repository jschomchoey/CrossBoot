# CrossBoot

A simple tool for creating Windows bootable USB drives on macOS.

![CrossBoot Screenshot](assets/screenshot.png)

## Features

- Clean, user-friendly interface
- Auto-split WIM files for FAT32 compatibility (supports >4GB files)
- Supports both Legacy BIOS and UEFI boot modes
- Secure Boot ready
- Drag-and-drop ISO support
- Real-time progress tracking
- Cancelable operations
- Prevents system sleep during processing
- Bypass Windows 11 restrictions (TPM, Secure Boot, & Online Account)

## Requirements

- macOS 11 or later
- Mac Apple Silicon or Intel
- Windows ISO file
- USB drive (8GB or larger recommended)

## Installation

Download the latest release from the releases page and install the application.

**Note:** This app is not signed with an Apple Developer certificate. When running it for the first time, macOS Gatekeeper will block it. You'll need to allow the app in **System Settings > Privacy & Security** before you can run it.

## Usage

1. Insert your USB drive
2. Select the target USB drive from the dropdown
3. Choose your Windows ISO file (click to browse or drag-and-drop)
4. Optional: Enable "Bypass Windows 11 Requirements" if needed
5. Click "Create Bootable USB" and confirm
6. Wait for the process to complete

The tool will automatically format your USB drive to FAT32 and copy all necessary files. Large WIM files will be split automatically to ensure compatibility.

## Development

### Tech Stack

- Swift - Programming language
- SwiftUI - UI framework
- wimlib - WIM file manipulation

## Acknowledgments

This project uses [wimlib](https://wimlib.net/) for WIM file operations. Special thanks to the wimlib developers for their excellent tool.

## License

See LICENSE file for details.
