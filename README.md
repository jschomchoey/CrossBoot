# CrossBoot

A simple tool for creating Windows and macOS bootable USB drives on macOS.

![CrossBoot Screenshot](assets/screenshot.png)

## Features

- Clean, user-friendly interface
- Create macOS install media for any release Apple still publishes, older or newer than this Mac
- Combine several Windows versions on one drive, still bootable with Secure Boot on
- Auto-split WIM files for FAT32 compatibility (supports >4GB files)
- Supports both Legacy BIOS and UEFI boot modes
- Secure Boot ready
- Drag-and-drop ISO support
- Real-time progress tracking
- Cancelable operations
- Prevents system sleep during processing
- Bypass Windows 11 restrictions (TPM, Secure Boot, & Online Account)

## Requirements

- macOS 13 or later
- Mac Apple Silicon or Intel
- A Windows ISO file, or an internet connection for macOS media
- USB drive - 8 GB or larger for Windows, 32 GB or larger for macOS

## Installation

Download the latest release from the releases page and install the application.

**Note:** This app is not signed with an Apple Developer certificate. When running it for the first time, macOS Gatekeeper will block it. You'll need to allow the app in **System Settings > Privacy & Security** before you can run it.

## Usage

Pick **Windows** or **macOS** in the window's toolbar. The drive picker, the progress bar and the Create button
are the same for both.

### Windows

1. Insert your USB drive
2. Add one or more Windows ISO files (click "Add ISO…" or drag-and-drop)
3. Select the target USB drive from the dropdown
4. Optional: Enable "Bypass Windows 11 Requirements" if needed
5. Click "Create Bootable Drive" and confirm
6. Wait for the process to complete

The tool will automatically format your USB drive to FAT32 and copy all necessary files. Large WIM files will be split automatically to ensure compatibility.

### Multi-version drives

Add more than one ISO and CrossBoot builds a single drive that offers all of them. Windows Setup lists every
edition it found, labelled with its build number, and you pick one at install time.

The drive stays Secure Boot compatible because the boot chain is never rebuilt. The newest ISO supplies every
boot binary - `bootmgfw.efi`, `boot.wim` and setup - copied byte for byte, so firmware sees the same Microsoft
signatures as on single-version media. Only `sources/install.wim` is rewritten, and Windows Setup reads that as
data long after the firmware has handed over. There is no shim to install and no key to enroll.

Two limits follow from how Windows Setup works:

- **One architecture per drive.** x64 and ARM64 firmware each load their own boot loader, and both loaders can sit
  on one drive. What they cannot share is what comes next: a single `\sources\boot.wim` and a single BCD, both at
  fixed paths. Separating them means authoring a new BCD, which is a Windows registry hive, so CrossBoot refuses
  the combination when you add the second ISO rather than after erasing the drive.
- **The newest Windows supplies setup.** Its setup can deploy older images; an older setup cannot deploy newer
  ones. CrossBoot picks the base ISO for you.

Merging rewrites the install image on your Mac before anything reaches the drive, so it needs free scratch space
of roughly twice the combined size of the source install images - half again more when they are `install.esd`,
which is solid-compressed and has to be rewritten in a format that can be split for FAT32. CrossBoot checks for
the space up front, and the drive is not erased until the rewriting and splitting are finished, so a run that
cannot complete leaves it as it was.

## macOS installers

Switch to **macOS** and CrossBoot lists the releases Apple still publishes. Pick one, pick a drive, and it
downloads the installer and hands it to Apple's own `createinstallmedia`.

### Any version, not just this Mac's

`softwareupdate --list-full-installers` answers with what Apple serves *your* machine, so it can never offer a
release newer than the one you are entitled to. CrossBoot reads Apple's software update catalog directly
instead, which is not filtered by hardware, so both older and newer releases are listed. Four sources feed the
list:

- **Apple's catalog** - every `InstallAssistant.pkg` Apple publishes, roughly 12 GB to 18 GB each.
- **Software Update** - what `softwareupdate` offers this Mac, used only for anything the catalog did not carry.
- **/Applications** - an `Install macOS X.app` already on this Mac, left by an earlier run or by Apple's own
  download. It is listed as **Local installer** and used as it is, so a release you already have is never
  offered as a download again.
- **A local installer** - an `Install macOS X.app` or an `InstallAssistant.pkg` kept anywhere else, dropped on
  the window or chosen from the menu beside **macOS Version**.

The version menu marks the releases this Mac cannot build, and picking one says why. Two limits are enforced
before anything is erased:

- **A release that needs a newer macOS than you are running** cannot be expanded here, and the catalog says so
  per release.
- **A release older than Big Sur cannot be built on Apple Silicon.** The media would write successfully and then
  boot nothing.

Versions this Mac cannot build are hidden until you ask for them in the menu beside **macOS Version**.

### Full Disk Access

`createinstallmedia`'s last step - making the drive bootable - is refused by macOS unless the process doing it
has Full Disk Access, and an app cannot lend its own to a root process raised the usual way: every form of
*"do shell script with administrator privileges"* goes through the authorization trampoline, which does not
carry the grant. The drive gets written and then cannot be blessed.

So CrossBoot asks for your administrator password itself and hands it to `sudo` on its standard input. The step
is then a direct child of the app and inherits what the app holds. Switch **CrossBoot** on under
**System Settings > Privacy & Security > Full Disk Access**, reopen it, and run. CrossBoot appears in that list
after it has been refused once, which it asks for itself when you switch to macOS media.

The password goes from the panel into sudo and nowhere else: never an argument, never an environment variable,
never a file, never a log. The step also checks for that access itself, before the drive is erased, so a
refusal costs you nothing.

### What it does to your Mac

Writing macOS media needs `createinstallmedia`, which needs root, so CrossBoot asks for your administrator
password once per run - when you press the button, not an hour later. The privileged step then waits for the
download to finish, so nothing interrupts a run halfway through. It is a single step, and nothing you chose is
ever spliced into a command: every path is one item of the step's argv.

The drive is checked twice: once before the password prompt, and again as root immediately before the erase,
because downloading an installer can take an hour and a drive can be swapped in that time. It has to still be
external, still removable, and still exactly the size it was.

Preparing the installer leaves `Install macOS X.app` in `/Applications`. CrossBoot tells you it is there, and
Advanced Options can delete it once the drive is written.

The download is checked against the byte count Apple publishes and discarded if it disagrees, so a truncated
transfer fails before the drive is touched rather than after.

How the progress bar is divided depends on what the run has to do. An installer already in `/Applications` is
written straight to the drive, so the write owns almost all of the bar; one downloaded from Apple shares it
with the download and with expanding the package. A run never spends part of the bar on a step it is not
taking.

Writing the drive is most of a run - 15 GB onto a USB stick - and `createinstallmedia` prints nothing at all
while it copies. The privileged step therefore samples the kernel's I/O counter for the device every ten
seconds, and that is what moves the second half of the progress bar. It is read from the counter rather than
from the volume because anything that touches a drive being written this hard stalls for seconds, and a
progress bar must not be one of the things making that worse.

## Development

### Tech Stack

- Swift - Programming language
- SwiftUI - UI framework
- wimlib - WIM file manipulation
- createinstallmedia - Apple's own tool, used unchanged for macOS media

## Acknowledgments

This project uses [wimlib](https://wimlib.net/) for WIM file operations. Special thanks to the wimlib developers for their excellent tool.

## License

See LICENSE file for details.
