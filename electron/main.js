import { app, BrowserWindow, ipcMain, dialog } from "electron";
import { fileURLToPath } from "url";
import path from "path";
import drivelist from "drivelist";
import { exec, spawn } from "child_process";
import util from "util";
import fs from "fs/promises";
import fsLegacy from "fs";
import os from "os";

const execPromise = util.promisify(exec);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const WIMLIB_PATH = path.join(__dirname, "wimlib", "wimlib-imagex");

const createWindow = () => {
  const win = new BrowserWindow({
    width: 600,
    height: 550,
    icon: path.join(__dirname, "..", "src", "assets", "icon", "icon.icns"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  // Load from dev server in development, or from built files in production
  if (process.env.VITE_DEV_SERVER_URL) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    win.loadFile(path.join(__dirname, "..", "dist", "index.html"));
  }
  // win.webContents.openDevTools();
};

// --- Helper Functions ---

// Find USB Mount Point
async function getUsbMountPoint(devicePath) {
  await new Promise((r) => setTimeout(r, 3000));

  const drives = await drivelist.list();
  const drive = drives.find((d) => d.device === devicePath);

  if (drive && drive.mountpoints.length > 0) {
    return drive.mountpoints[0].path;
  }
  throw new Error(
    "Could not find USB mount point. Please try re-inserting the USB."
  );
}

// Scan all files
async function getAllFiles(dir) {
  let results = [];
  const list = await fs.readdir(dir);
  for (const file of list) {
    const filePath = path.join(dir, file);
    const stat = await fs.stat(filePath);
    if (stat && stat.isDirectory()) {
      results = results.concat(await getAllFiles(filePath));
    } else {
      results.push({ path: filePath, size: stat.size });
    }
  }
  return results;
}

app.whenReady().then(() => {
  ipcMain.handle("get-disks", async () => {
    try {
      const drives = await drivelist.list();
      const filteredDrives = drives.filter(
        (drive) => !drive.isSystem && drive.isRemovable && drive.isUSB
      );
      return filteredDrives;
    } catch (error) {
      console.error(error);
      return [];
    }
  });

  ipcMain.handle("select-iso", async () => {
    const result = await dialog.showOpenDialog({
      properties: ["openFile"],
      filters: [{ name: "Disk Image (ISO)", extensions: ["iso"] }],
    });

    if (result.canceled) {
      return null;
    }

    const filePath = result.filePaths[0];

    // Get file stats for size and name
    try {
      const stats = await fs.stat(filePath);
      const sizeInBytes = stats.size;
      const sizeInGB = (sizeInBytes / (1024 * 1024 * 1024)).toFixed(2);
      const fileName = path.basename(filePath);

      return {
        path: filePath,
        name: fileName,
        size: `${sizeInGB} GB`,
        sizeBytes: sizeInBytes,
      };
    } catch (error) {
      // Fallback to just return path if stat fails
      return filePath;
    }
  });

  ipcMain.handle("get-file-info", async (event, filePath) => {
    try {
      const stats = await fs.stat(filePath);
      const sizeInBytes = stats.size;
      const sizeInGB = (sizeInBytes / (1024 * 1024 * 1024)).toFixed(2);
      const fileName = path.basename(filePath);

      return {
        path: filePath,
        name: fileName,
        size: `${sizeInGB} GB`,
        sizeBytes: sizeInBytes,
      };
    } catch (error) {
      console.error("Error getting file info:", error);
      return null;
    }
  });

  ipcMain.handle("format-usb", async (event, diskPath) => {
    console.log(`Starting format on: ${diskPath}`);

    // prevent formatting system disk
    if (!diskPath || diskPath.includes("disk0")) {
      return { success: false, message: "Invalid disk path (Safety blocked)" };
    }

    try {
      // diskutil eraseDisk [Format] [Name] [Scheme] [Device]
      const command = `diskutil eraseDisk MS-DOS "Windows" MBR "${diskPath}"`;

      const { stdout, stderr } = await execPromise(command);

      return { success: true, message: "Format Complete" };
    } catch (error) {
      console.error("Format Error:", error);
      return { success: false, message: error.message };
    }
  });

  ipcMain.handle("prepare-iso", async (event, isoPath) => {
    const webContents = event.sender;

    let mountPoint = "";

    try {
      // Mount ISO -nobrowse
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
      //   const sizeGB = stats.size / (1024 * 1024 * 1024);

      // Split if > 4GB
      if (stats.size > 4 * 1024 * 1024 * 1024) {
        const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "crossboot-"));
        const destPath = path.join(tempDir, "install.swm");

        return new Promise((resolve, reject) => {
          const splitProcess = spawn(WIMLIB_PATH, [
            "split",
            wimPath,
            destPath,
            "3800",
          ]);

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
            console.error(`Wimlib Error: ${data}`);
          });

          // When finished
          splitProcess.on("close", (code) => {
            if (code === 0) {
              resolve({
                success: true,
                action: "split",
                mountPoint,
                tempDir,
                message: "Split complete",
              });
            } else {
              reject(new Error(`Wimlib exited with code ${code}`));
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
      // Unmount if error
      if (mountPoint) {
        try {
          await execPromise(`hdiutil detach "${mountPoint}" -force`);
        } catch (e) {}
      }
      return { success: false, message: error.message };
    }
  });

  ipcMain.handle(
    "copy-to-usb",
    async (
      event,
      { isoMountPoint, usbDevice, isoAction, tempDir, bypassRequirements }
    ) => {
      const webContents = event.sender;

      try {
        // Find Real USB Path
        const destRoot = await getUsbMountPoint(usbDevice);

        // Build File List
        let filesToCopy = [];
        const isoFiles = await getAllFiles(isoMountPoint);

        for (const f of isoFiles) {
          const relativePath = path.relative(isoMountPoint, f.path);

          // skip install.wim if splitting
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

        // If splitting, add .swm files from Temp
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

        // Calculate Total Size
        const totalBytes = filesToCopy.reduce((acc, f) => acc + f.size, 0);
        let copiedBytes = 0;

        const BUFFER_SIZE = 32 * 1024 * 1024;

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

        // Add Windows 11 Bypass if enabled
        if (bypassRequirements) {
          try {
            // Create autounattend.xml to bypass TPM, Secure Boot, and RAM requirements
            const autounattendContent = `<?xml version="1.0" encoding="utf-8"?>
              <unattend xmlns="urn:schemas-microsoft-com:unattend">
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
                                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>3</Order>
                                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>4</Order>
                                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>5</Order>
                                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
                      </component>
                  </settings>
              </unattend>`;

            const autounattendPath = path.join(destRoot, "autounattend.xml");
            await fs.writeFile(autounattendPath, autounattendContent, "utf8");
            console.log("Created autounattend.xml for Windows 11 bypass");
          } catch (error) {
            console.error("Failed to create bypass files:", error);
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

  // Set dock icon for macOS
  if (process.platform === "darwin") {
    app.dock.setIcon(
      path.join(__dirname, "..", "src", "assets", "icon", "icon_2.png")
    );
  }

  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
