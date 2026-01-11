import { app, BrowserWindow } from "electron";
import { createWindow, setDockIcon } from "./window.js";
import { registerDiskHandlers } from "./handlers/diskHandlers.js";
import { registerIsoHandlers } from "./handlers/isoHandlers.js";
import { registerDialogHandlers } from "./handlers/dialogHandlers.js";
import { cleanupLeftovers } from "./utils/helpers.js";

app.setName("CrossBoot");

app.whenReady().then(async () => {
  await cleanupLeftovers();

  // Register all IPC handlers
  registerDiskHandlers();
  registerIsoHandlers();
  registerDialogHandlers();

  // Set dock icon for macOS
  setDockIcon();

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
