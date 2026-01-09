const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("electronAPI", {
  getDisks: () => ipcRenderer.invoke("get-disks"),
  selectIso: () => ipcRenderer.invoke("select-iso"),
  getFileInfo: (filePath) => ipcRenderer.invoke("get-file-info", filePath),
  formatUsb: (diskPath) => ipcRenderer.invoke("format-usb", diskPath),
  prepareIso: (isoPath) => ipcRenderer.invoke("prepare-iso", isoPath),
  copyToUsb: (data) => ipcRenderer.invoke("copy-to-usb", data),
  showDialog: (options) => ipcRenderer.invoke("show-dialog", options),
  onProgress: (callback) =>
    ipcRenderer.on("process-progress", (_event, value) => callback(value)),
  // prevent memory leak
  removeProgressListeners: () =>
    ipcRenderer.removeAllListeners("process-progress"),
});
