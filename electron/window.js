import { BrowserWindow, app } from "electron";
import { getIconPath, getPreloadPath, getDistPath } from "./utils/paths.js";

/**
 * Create the main application window
 * @returns {BrowserWindow} The created window instance
 */
export function createWindow() {
  const win = new BrowserWindow({
    width: 600,
    height: 575,
    resizable: false,
    icon: getIconPath(),
    webPreferences: {
      preload: getPreloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    win.loadFile(getDistPath());
  }

  // Uncomment to open DevTools
  // win.webContents.openDevTools();

  return win;
}

/**
 * Set the dock icon for macOS
 */
export function setDockIcon() {
  if (process.platform === "darwin") {
    app.dock.setIcon(getIconPath());
  }
}
