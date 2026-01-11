import { ipcMain, powerSaveBlocker } from "electron";
import { spawn } from "child_process";
import util from "util";
import { exec } from "child_process";
import path from "path";
import fs from "fs/promises";
import fsLegacy from "fs";
import os from "os";
import { WIMLIB_PATH } from "../utils/paths.js";
import { getUsbMountPoint, getAllFiles } from "../utils/helpers.js";

const execPromise = util.promisify(exec);

/**
 * Register all ISO-related IPC handlers
 */
export function registerIsoHandlers() {
  // Prepare ISO: Mount and optionally split WIM file
  ipcMain.handle("prepare-iso", async (event, isoPath) => {
    const blockerId = powerSaveBlocker.start("prevent-display-sleep");
    const webContents = event.sender;

    let mountPoint = "";

    try {
      // Mount ISO with -nobrowse option
      const { stdout } = await execPromise(
        `hdiutil mount -nobrowse "${isoPath}"`
      );

      // Parse mount point
      const match = stdout.match(/\/Volumes\/.+/);
      if (!match) throw new Error("Failed to get mount point");
      mountPoint = match[0].trim();

      const wimPath = path.join(mountPoint, "sources", "install.wim");

      try {
        await fs.access(wimPath);
      } catch {
        return {
          success: true,
          action: "copy",
          mountPoint,
          wimInfo: "install.wim not found (maybe .esd?), skipping split check.",
        };
      }

      const stats = await fs.stat(wimPath);

      // Split if > 4GB (FAT32 limit)
      if (stats.size > 4 * 1024 * 1024 * 1024) {
        const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "crossboot-"));
        const destPath = path.join(tempDir, "install.swm");

        return new Promise(async (resolve, reject) => {
          console.log("\n" + "=".repeat(60));
          console.log("📀 STARTING WIM SPLIT OPERATION");
          console.log("=".repeat(60));

          // Check if wimlib binary exists
          try {
            await fs.access(WIMLIB_PATH);
            console.log(`✅ Wimlib binary found at: ${WIMLIB_PATH}`);
          } catch (err) {
            console.error(`❌ Wimlib binary NOT found at: ${WIMLIB_PATH}`);
            console.error(`Error: ${err.message}`);
            reject(
              new Error(
                `Wimlib binary not found at ${WIMLIB_PATH}. Error: ${err.message}`
              )
            );
            return;
          }

          // Force set executable permission and remove quarantine attribute
          try {
            console.log("⚙️  Re-checking and fixing permissions...");
            const { stdout: beforePerms } = await execPromise(
              `ls -la "${WIMLIB_PATH}"`
            );
            console.log(`📋 Permissions before: ${beforePerms.trim()}`);

            await execPromise(`chmod +x "${WIMLIB_PATH}"`);
            console.log("✅ chmod +x applied");

            // Remove macOS quarantine attribute that blocks execution
            await execPromise(
              `xattr -d com.apple.quarantine "${WIMLIB_PATH}" 2>/dev/null || true`
            );
            console.log("✅ Quarantine attribute removed");

            const { stdout: afterPerms } = await execPromise(
              `ls -la "${WIMLIB_PATH}"`
            );
            console.log(`📋 Permissions after: ${afterPerms.trim()}`);
          } catch (err) {
            console.warn(
              `⚠️  Warning: Could not modify wimlib permissions: ${err.message}`
            );
          }

          console.log(`🚀 Spawning wimlib process...`);
          console.log(
            `   Command: wimlib-imagex split "${wimPath}" "${destPath}" 3800`
          );

          const splitProcess = spawn(WIMLIB_PATH, [
            "split",
            wimPath,
            destPath,
            "3800",
          ]);

          console.log(
            `✅ Process spawned with PID: ${splitProcess.pid || "unknown"}`
          );

          // Handle process spawn error
          splitProcess.on("error", (err) => {
            console.error("❌ SPAWN ERROR:", err.message);
            console.error("Error code:", err.code);
            console.error("Error stack:", err.stack);
            reject(
              new Error(
                `Failed to spawn wimlib process: ${err.message}. Path: ${WIMLIB_PATH}`
              )
            );
          });

          // Capture output from wimlib
          splitProcess.stdout.on("data", (data) => {
            const output = data.toString();
            const match = output.match(/(\d+)%/);
            if (match) {
              const percent = parseInt(match[1]);
              webContents.send("process-progress", {
                stage: "split",
                percent: percent,
              });
              console.log(`Split Progress: ${percent}%`);
            }
          });

          splitProcess.stderr.on("data", (data) => {
            console.error(`⚠️  Wimlib STDERR: ${data}`);
          });

          // When finished
          splitProcess.on("close", (code) => {
            console.log(`\n🏁 Wimlib process finished with code: ${code}`);
            console.log("=".repeat(60) + "\n");

            if (code === 0) {
              console.log("✅ Split completed successfully!");
              resolve({
                success: true,
                action: "split",
                mountPoint,
                tempDir,
                message: "Split complete",
              });
            } else {
              console.error(`❌ Wimlib failed with exit code: ${code}`);
              console.error(`Binary path: ${WIMLIB_PATH}`);
              reject(
                new Error(
                  `Wimlib exited with code ${code}. Binary path: ${WIMLIB_PATH}`
                )
              );
            }
          });
        });
      } else {
        console.log("File is under 4GB. Ready to copy.");
        return {
          success: true,
          action: "copy",
          mountPoint,
          message: "WIM file is small enough, no split needed.",
        };
      }
    } catch (error) {
      console.error("ISO Process Error:", error);
      // Unmount if error occurs
      if (mountPoint) {
        try {
          await execPromise(`hdiutil detach "${mountPoint}" -force`);
        } catch (e) {}
      }
      return { success: false, message: error.message };
    } finally {
      if (powerSaveBlocker.isStarted(blockerId)) {
        powerSaveBlocker.stop(blockerId);
      }
    }
  });

  // Copy ISO contents to USB
  ipcMain.handle(
    "copy-to-usb",
    async (
      event,
      {
        isoMountPoint,
        usbDevice,
        isoAction,
        tempDir,
        bypassRequirements,
        bypassOnlineAccount,
      }
    ) => {
      const webContents = event.sender;

      try {
        // Find real USB path
        const destRoot = await getUsbMountPoint(usbDevice);

        // Build file list
        let filesToCopy = [];
        const isoFiles = await getAllFiles(isoMountPoint);

        for (const f of isoFiles) {
          const relativePath = path.relative(isoMountPoint, f.path);

          // Skip install.wim if splitting
          if (
            isoAction === "split" &&
            relativePath.toLowerCase().endsWith("install.wim")
          ) {
            continue;
          }

          filesToCopy.push({
            src: f.path,
            dest: path.join(destRoot, relativePath),
            size: f.size,
          });
        }

        // If splitting, add .swm files from temp
        if (isoAction === "split" && tempDir) {
          const tempFiles = await getAllFiles(tempDir);
          for (const f of tempFiles) {
            filesToCopy.push({
              src: f.path,
              dest: path.join(destRoot, "sources", path.basename(f.path)),
              size: f.size,
            });
          }
        }

        // Calculate total size
        const totalBytes = filesToCopy.reduce((acc, f) => acc + f.size, 0);
        let copiedBytes = 0;

        const BUFFER_SIZE = 32 * 1024 * 1024; // 32MB buffer

        // Copy files with progress tracking
        for (const file of filesToCopy) {
          await fs.mkdir(path.dirname(file.dest), { recursive: true });

          await new Promise((resolve, reject) => {
            const readStream = fsLegacy.createReadStream(file.src, {
              highWaterMark: BUFFER_SIZE,
            });
            const writeStream = fsLegacy.createWriteStream(file.dest, {
              highWaterMark: BUFFER_SIZE,
            });

            readStream.on("data", (chunk) => {
              copiedBytes += chunk.length;

              const percent = Math.min(
                100,
                Math.round((copiedBytes / totalBytes) * 100)
              );
              webContents.send("process-progress", {
                stage: "copy",
                percent,
                currentFile: path.basename(file.src),
              });
            });

            readStream.on("error", reject);
            writeStream.on("error", reject);
            writeStream.on("finish", resolve);

            readStream.pipe(writeStream);
          });
        }

        // Add autounattend.xml for bypass options
        if (bypassRequirements || bypassOnlineAccount) {
          try {
            let autounattendContent = `
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">`;

            // Add Windows 11 Requirements Bypass (windowsPE pass)
            if (bypassRequirements) {
              autounattendContent += `
                <settings pass="windowsPE">
                    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                        <UserData>
                            <ProductKey>
                                <Key></Key>
                            </ProductKey>
                        </UserData>
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>3</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>4</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>5</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
                    </component>
                </settings>`;
            }

            // Add Microsoft Online Account Bypass (specialize pass)
            if (bypassOnlineAccount) {
              autounattendContent += `
                <settings pass="specialize">
                    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
                    </component>
                </settings>`;
            }

            autounattendContent += `
            </unattend>`;

            const autounattendPath = path.join(destRoot, "autounattend.xml");
            await fs.writeFile(autounattendPath, autounattendContent, "utf8");
            console.log("Created autounattend.xml with bypass options");
          } catch (error) {
            console.error("Failed to create autounattend.xml:", error);
          }
        }

        // Cleanup
        try {
          await execPromise(`hdiutil detach "${isoMountPoint}" -force`);
        } catch (e) {}
        if (tempDir) {
          try {
            await fs.rm(tempDir, { recursive: true, force: true });
          } catch (e) {}
        }

        return { success: true, message: "Bootable USB Created Successfully!" };
      } catch (error) {
        console.error(error);
        return { success: false, message: error.message };
      }
    }
  );
}
