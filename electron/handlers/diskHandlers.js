import { ipcMain, dialog } from "electron";
import drivelist from "drivelist";
import util from "util";
import { exec } from "child_process";
import { getFileInfo } from "../utils/helpers.js";

const execPromise = util.promisify(exec);

/**
 * Register all disk-related IPC handlers
 */
export function registerDiskHandlers() {
  // Get list of removable USB disks
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

  // Select ISO file from dialog
  ipcMain.handle("select-iso", async () => {
    const result = await dialog.showOpenDialog({
      properties: ["openFile"],
      filters: [{ name: "Disk Image (ISO)", extensions: ["iso"] }],
    });

    if (result.canceled) {
      return null;
    }

    const filePath = result.filePaths[0];

    try {
      return await getFileInfo(filePath);
    } catch (error) {
      return filePath;
    }
  });

  // Get file information
  ipcMain.handle("get-file-info", async (event, filePath) => {
    try {
      return await getFileInfo(filePath);
    } catch (error) {
      console.error("Error getting file info:", error);
      return null;
    }
  });

  // Format USB drive
  ipcMain.handle("format-usb", async (event, diskPath) => {
    console.log(`Starting format on: ${diskPath}`);

    // Prevent formatting system disk
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
}
