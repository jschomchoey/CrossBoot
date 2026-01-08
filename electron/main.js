import { app, BrowserWindow, ipcMain, dialog } from "electron";
import { fileURLToPath } from "url";
import path from "path";
import drivelist from "drivelist";
import { exec } from "child_process";
import util from "util";

const execPromise = util.promisify(exec);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

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
