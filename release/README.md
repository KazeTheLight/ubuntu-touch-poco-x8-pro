# Poco X8 Pro (klee): installing Ubuntu Touch

There are two ways to install:
- **Dual boot** (`install.sh`): keeps Android. Described first, below.
- **Standalone** (`install-standalone.sh`): replaces Android and erases its data. See
  [Standalone install](#standalone-install-replaces-android).

With the dual boot install, Axion and your /data are **never wiped or formatted**. Ubuntu Touch is installed into a new
logical partition (`ut_data`) in the free space of the super partition. Switching between the two
systems only swaps the active slot's `boot` + `init_boot` images.

The images are not in this repository. On Linux, build them with `port/build-klee.sh`; it writes
them to `release/images/`. On Windows, build them in GitHub Actions and download the artifacts
(see [Installing from Windows](#installing-from-windows)).

## Contents

| File | Purpose |
|---|---|
| `images/ut_boot.img` | Ubuntu Touch kernel: UBports android15-6.6-halium GKI, same KMI as the phone's 6.6.89 |
| `images/ut_init_boot.img` | Halium initramfs + klee patches: slot-aware super mapping, safety checks |
| `images/ubuntu.img` | Ubuntu Touch 24.04-1.x rootfs (Halium 14) + klee overlay + 6.6 modules |
| `images/ut_boot_fastboot-boot.img` | For a one-off `fastboot boot` test without flashing |
| `install.sh` | Installer: takes backups, creates `ut_data`, writes the rootfs |
| `boot-ubuntu.sh` / `boot-axion.sh` | Switch systems from the computer |
| `device/to-ubuntu.sh` | Switch to Ubuntu from the phone (Axion, root) |
| `install-windows.ps1` | Windows installer: same dual boot install, but uses the prebuilt `ut_data.img` |
| `boot-ubuntu.ps1` | Switch to Ubuntu Touch from Windows |
| `boot-android.ps1` | Switch back to Android from Windows |
| `try-ubuntu-noflash.sh` | Experimental: tries to boot Ubuntu once without writing anything |
| `collect-logs.sh` | Debug logs |
| `uninstall.sh` | Removes the dual boot Ubuntu Touch completely |
| `install-standalone.sh` | Standalone installer: replaces Android, **erases all Android data** |
| `restore-android.sh` | Goes back from a standalone install to Android |

## Installation

Start with the phone running Axion and USB debugging enabled.

1. In the KernelSU manager, grant root to the **Shell** app.
2. Do a dry run first. It changes nothing on the phone; it only takes backups and prepares the image:
   ```
   ./install.sh --dry-run
   ```
3. Run the real installation:
   ```
   ./install.sh
   ```
   It backs up the phone, enters `fastbootd`, creates `ut_data`, flashes the images and returns
   to Axion.

   Backups are saved to `backup-<date>/`, and `backup-latest` points to the newest one.
   - **Do not delete this folder.** You need it to return to Axion.
   - The same backups are also copied into `ut_data`.

## Standalone install (replaces Android)

**Not tested on a device. It erases all Android data**, including internal storage, photos,
apps and chats. Copy everything you want to keep to a computer first.

Ubuntu Touch gets the whole `userdata` partition, formatted as ext4, so there is far more room
than with the dual boot install (which is limited to the free space in super). The kernel,
ramdisk and rootfs are exactly the same as for dual boot. If the `ut_data` partition does not
exist, the initramfs uses `userdata` instead, and only when `userdata` is ext4. Android's own
encrypted userdata is refused, and the boot stops before anything is written.

1. Boot into Android with USB debugging on, and grant root to the **Shell** app in KernelSU.
   Root is only needed for the backups.
2. Dry run first. It takes the backups and builds the image, but changes nothing on the phone:
   ```
   ./install-standalone.sh --dry-run
   ```
3. Real install:
   ```
   ./install-standalone.sh
   ```
   - It backs up `boot`, `init_boot` and the IMEI/NVRAM partitions to
     `backup-standalone-<date>/`. **Copy this folder off the computer as well.**
   - It asks you to type `ERASE` before it changes anything.
   - Then it reboots into the bootloader, flashes `boot`/`init_boot`, writes Ubuntu Touch to
     `userdata` and boots it.
   - On the first boot the filesystem grows to fill the whole partition.

If a dual boot `ut_data` partition already exists, the installer stops: the initramfs would keep
using it. Run `./uninstall.sh` first.

The IMEI warning applies here too: the SELinux guard service runs in standalone mode as well, but
if you ever go back to Android, check the modem/IMEI first.

**Back to Android:** enter the bootloader (Volume Down + Power, or
`systemctl reboot --reboot-argument=bootloader` in Ubuntu Touch), then run:
```
./restore-android.sh backup-standalone-<date>
```
It flashes Android's `boot`/`init_boot` back and starts the recovery. There, choose **Format
Data**, then reboot. Android starts with a fresh setup. The "Switch to Android" app inside Ubuntu
Touch only works for the dual boot install.

## Installing from Windows

`install.sh` cannot run on Windows: it needs `mkfs.ext4`, `debugfs`, `e2fsck` and `img2simg`, none
of which exist there. The PowerShell installer therefore works differently: the `ut_data` ext4
image is built on Linux by the GitHub Actions workflow and downloaded as the `klee-utdata`
artifact. Windows itself only needs `adb` and `fastboot`, which are already in `platform-tools`.

Build in Actions
----------------

1. Push to the fork `KazeTheLight/ubuntu-touch-poco-x8-pro` and run the **Build klee images**
   workflow.
2. When it finishes, download and unzip these artifacts into `release/images/`:

   | Artifact | File needed in `images/` |
   |---|---|
   | `klee-boot-images` | `ut_boot.img`, `ut_init_boot.img` |
   | `klee-rootfs` | `ubuntu.img` |
   | `klee-utdata` | `ut_data.img` |

Install from Windows
--------------------

Start with the phone booted into Android, USB debugging on, and root granted to the **Shell** app
in the KernelSU manager.

1. Check everything first. This only takes backups and reads `super`; it changes nothing:
   ```
   .\install-windows.ps1 -DryRun
   ```
   It fails early if the phone is not `klee`, has no root, or has too little free space in
   `super` (minimum 2560 MiB).
2. Real install:
   ```
   .\install-windows.ps1
   ```
   It backs up the phone, reboots to `fastbootd`, creates `ut_data` in the free space of `super`,
   flashes it, and returns to Android.

   Backups go to `backup-<date>/`, with `backup-latest` pointing at the newest. **Do not delete
   them** — you need them to return to Android.

The size of `ut_data` is detected automatically (the free space in `super`, capped at 6144 MiB).
Pass `-UtDataMib <n>` to override it; use the same value the `ut_data.img` artifact was built
with.

Switching systems
-----------------

- **To Ubuntu:** `.\boot-ubuntu.ps1`, or on the phone as root:
  `su -c sh /sdcard/klee-ut/to-ubuntu.sh`.
- **Back to Android:** `.\boot-android.ps1`.

Both need the phone reachable, either over adb or already in bootloader fastboot
(Volume Down + Power).

## Switching systems

- **To Ubuntu:** run `./boot-ubuntu.sh`. Or, on the phone in Axion as root:
  `su -c sh /sdcard/klee-ut/to-ubuntu.sh`.
- **Back to Axion:**
  1. From flashed Ubuntu Touch, enter the bootloader (fastboot):
     `systemctl reboot --reboot-argument=bootloader`, or hold **Volume Down + Power** if the
     phone does not boot.
  2. Run `./boot-axion.sh`.

  Do not use `klee-boot-android` (or `dd` from inside Ubuntu Touch): the active slot's boot
  partitions are write-protected there, and that path once caused a BROM loop.
- The bootloader (LK) is never touched, so fastboot is always reachable.
- `adb reboot fastboot` (fastbootd) does not work while Ubuntu is active. Use bootloader fastboot.

## First boot / debugging

- The first boot can take a few minutes, and the screen may stay on the logo.
- **No UI:** keep the USB cable plugged in. Ubuntu Touch "rescue mode" opens a USB network
  interface:
  ```
  ssh -p 8022 phablet@10.15.19.82
  ```
  No password is needed. Then run `./collect-logs.sh ubuntu`.
- **Failure in the initramfs stage:** the phone opens telnet over USB:
  ```
  telnet 192.168.2.15
  ```
- **Neither works:**
  1. Hold Volume Down + Power and run `./boot-axion.sh`.
  2. Once Axion is up, run `./collect-logs.sh android`. It reads the previous boot's kernel log
     from pstore.

## Safety measures (to protect Axion's data)

- Ubuntu Touch **never** touches `userdata`. If `datapart` is not found, the boot stops. It also
  stops if the partition is not ext4.
- `/metadata`, which holds Axion's encryption keys, is never mounted. The container sees an empty
  tmpfs.
- The vendor's `mount_all`/`swapon_all` commands are neutralised at runtime.

## Known risks / limitations

- A Halium 14 (Android 14) system runs on an Android 16 vendor. For compatibility:
  - a missing symbol was added to `libbinder_ndk.so`
  - VINTF 9.0 manifests are presented as 8.0

  On the device this worked through the UI and modem detection; Wi-Fi did not work. Other HALs are untested.
- Do not expect audio (AIDL audio HAL v2), camera, fingerprint or VoLTE to work on the first try.
  The goal was boot + display + touch + Wi-Fi first.

## Display settings (punch hole / status bar)

These values come from Axion's display configuration:
- screen 1268×2756
- camera hole at the top centre, 78×102 px
- corner radius 190 px

The port adjusts Lomiri to match:
- **Status bar:** 120 px. Lomiri's default of 72 px overlapped the camera hole.
- **Status bar icons:** 64 px margin on the left and right, so the rounded corners do not cut them off.
- **UI scale:** GridUnit 24 (`/etc/deviceinfo/devices/halium.yaml`).

To try other values on the phone (Ubuntu Touch terminal):
```
sudo mount -o remount,rw /
sudo nano /usr/share/lomiri/Shell.qml          # the 120 on the "klee: clear the punch-hole" line
sudo nano /usr/share/lomiri/Panel/PanelMenu.qml # leftMargin/rightMargin: 64
sudo nano /etc/deviceinfo/devices/halium.yaml   # GridUnit (bigger = everything bigger)
sudo mount -o remount,ro /
restart lomiri   # or reboot the phone
```
The permanent values are set at build time in `port/rootfs-patches/lomiri-klee.sh`.

## IMEI / SIM

- **Backup:** before Ubuntu boots for the first time, `install.sh` backs up the partitions that
  hold the IMEI and modem data (nvram, nvdata, nvcfg, protect1/2, md_sec, persist, proinfo) to
  `backup-<date>/imei/`. **Copy this folder somewhere else as well.**
- **Restore:** if the IMEI is ever lost, boot into the bootloader (fastboot) and run
  `fastboot flash nvdata nvdata.img`, and the same for the other partitions.
- **Read the IMEI incident in [../docs/DEVELOPMENT-NOTES.md](../docs/DEVELOPMENT-NOTES.md) first.**
  Losing the SELinux labels is the real danger, not the data itself.
- **SIM/calls:** Ubuntu Touch has ofono + binder RIL + the MTK plugin, but they are not guaranteed
  to work with the Android 16 RIL on the first try. Get boot and display working first, then the SIM.
