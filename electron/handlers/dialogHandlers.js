import { ipcMain, dialog, BrowserWindow } from "electron";
import { getIconPath } from "../utils/paths.js";

/**
 * Register all dialog-related IPC handlers
 */
export function registerDialogHandlers() {
  // Show dialog box
  ipcMain.handle("show-dialog", async (event, { type, title, message }) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    const iconPath = getIconPath();

    const result = await dialog.showMessageBox(win, {
      type: type || "info", // 'info', 'error', 'question', 'warning'
      title: title,
      message: message,
      buttons: ["OK"],
      defaultId: 0,
      icon: iconPath,
    });

    return result.response;
  });
}
