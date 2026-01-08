const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("electronAPI", {
  getDisks: () => ipcRenderer.invoke("get-disks"),
  selectIso: () => ipcRenderer.invoke("select-iso"),
  formatUsb: (diskPath) => ipcRenderer.invoke("format-usb", diskPath),
});
