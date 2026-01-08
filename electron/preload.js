const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("electronAPI", {
  getDisks: () => ipcRenderer.invoke("get-disks"),
});
