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
    width: 800,
    height: 600,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadURL("http://localhost:5173");
  win.webContents.openDevTools();
};

app.whenReady().then(() => {
  ipcMain.handle("get-disks", async () => {
    try {
      const drives = await drivelist.list();
      const filteredDrives = drives.filter(
        (drive) => !drive.isSystem && drive.isRemovable && drive.isUSB
      );
      return filteredDrives; // Return filtered disks
    } catch (error) {
      console.error(error);
      return [];
    }
  });

  ipcMain.handle("select-iso", async () => {
    const result = await dialog.showOpenDialog({
      properties: ["openFile"],
      filters: [
        { name: "Disk Image (ISO)", extensions: ["iso"] }, // .iso
      ],
    });

    if (result.canceled) {
      return null;
    }

    return result.filePaths[0];
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
      //   console.log("Format Output:", stdout);

      return { success: true, message: "Format Complete" };
    } catch (error) {
      console.error("Format Error:", error);
      return { success: false, message: error.message };
    }
  });

  ipcMain.handle("prepare-iso", async (event, isoPath) => {
    const webContents = event.sender;

    console.log(`Processing ISO: ${isoPath}`);
    let mountPoint = "";

    try {
      // 1. Mount ISO -nobrowse
      console.log("Mounting ISO...");
      const { stdout } = await execPromise(
        `hdiutil mount -nobrowse "${isoPath}"`
      );

      // Parse mount point from output (e.g., /dev/disk2 /Volumes/CCCOMA_X64FRE_EN-US_DV9)
      const match = stdout.match(/\/Volumes\/.+/);
      if (!match) throw new Error("Failed to get mount point");
      mountPoint = match[0].trim();
      console.log(`Mounted at: ${mountPoint}`);

      // 2. Check install.wim size
      const wimPath = path.join(mountPoint, "sources", "install.wim");

      // เช็คว่ามีไฟล์ไหม (บาง ISO อาจเป็น .esd)
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
      const sizeGB = stats.size / (1024 * 1024 * 1024);
      console.log(`install.wim size: ${sizeGB.toFixed(2)} GB`);

      // 3. Logic: Split if > 4GB
      if (stats.size > 4 * 1024 * 1024 * 1024) {
        console.log("Large file detected. Starting Split process...");
        const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "crossboot-"));
        const destPath = path.join(tempDir, "install.swm");

        // ใช้ spawn แทน exec เพื่อดู Real-time progress
        return new Promise((resolve, reject) => {
          const splitProcess = spawn(WIMLIB_PATH, [
            "split",
            wimPath,
            destPath,
            "3800",
          ]);

          // ดักจับค่าที่ wimlib พ่นออกมา (stdout)
          splitProcess.stdout.on("data", (data) => {
            const output = data.toString();
            // wimlib จะพ่น output ประมาณ: "Splitting WIM: 1250 MiB of 4500 MiB (27%) written"
            // เราใช้ Regex หาตัวเลข %
            const match = output.match(/(\d+)%/);
            if (match) {
              const percent = parseInt(match[1]);
              // ส่งค่ากลับไปที่ React ชื่อ channel "process-progress"
              webContents.send("process-progress", {
                stage: "split",
                percent: percent,
              });
              console.log(`Split Progress: ${percent}%`);
            }
          });

          // ดักจับ Error
          splitProcess.stderr.on("data", (data) => {
            console.error(`Wimlib Error: ${data}`);
          });

          // เมื่อทำงานเสร็จ (Close)
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
          action: "copy", // บอกหน้าบ้านว่าแค่ copy ปกติก็พอ
          mountPoint,
          message: "WIM file is small enough, no split needed.",
        };
      }
    } catch (error) {
      console.error("ISO Process Error:", error);
      // ถ้า Error ให้พยายาม Unmount ทิ้งด้วย
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
    async (event, { isoMountPoint, usbDevice, isoAction, tempDir }) => {
      const webContents = event.sender;

      try {
        console.log("Starting Copy Process...");

        // 5.1 Find Real USB Path
        const destRoot = await getUsbMountPoint(usbDevice);
        console.log(`Destination: ${destRoot}`);

        // 5.2 Build File List
        let filesToCopy = [];
        const isoFiles = await getAllFiles(isoMountPoint);

        for (const f of isoFiles) {
          const relativePath = path.relative(isoMountPoint, f.path);

          // ถ้าเป็นโหมด Split ให้ข้าม install.wim ตัวใหญ่
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

        // ถ้า Split ให้เพิ่มไฟล์ .swm จาก Temp
        if (isoAction === "split" && tempDir) {
          const tempFiles = await getAllFiles(tempDir);
          for (const f of tempFiles) {
            filesToCopy.push({
              src: f.path,
              dest: path.join(destRoot, "sources", path.basename(f.path)), // เอาลง folder sources
              size: f.size,
            });
          }
        }

        // 5.3 Calculate Total Size
        const totalBytes = filesToCopy.reduce((acc, f) => acc + f.size, 0);
        let copiedBytes = 0;

        // 5.4 Copy Loop
        // TUNE: เพิ่ม Buffer Size เป็น 32MB เพื่อความเร็ว
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

              // Send Progress (Throttle ได้ถ้าต้องการ)
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
