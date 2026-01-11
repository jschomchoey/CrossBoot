import { app } from "electron";
import { fileURLToPath } from "url";
import path from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const WIMLIB_PATH = app.isPackaged
  ? path.join(process.resourcesPath, "wimlib", "wimlib-imagex")
  : path.join(__dirname, "..", "wimlib", "wimlib-imagex");

export const getIconPath = () => {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "icon", "icon_2.png");
  } else {
    return path.join(
      __dirname,
      "..",
      "..",
      "src",
      "assets",
      "icon",
      "icon_2.png"
    );
  }
};

export const getPreloadPath = () => {
  return path.join(__dirname, "..", "preload.js");
};

export const getDistPath = () => {
  return path.join(__dirname, "..", "..", "dist", "index.html");
};
