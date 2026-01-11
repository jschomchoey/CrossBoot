import { app, BrowserWindow } from "electron";
import { createWindow, setDockIcon } from "./window.js";
import { registerDiskHandlers } from "./handlers/diskHandlers.js";
import { registerIsoHandlers } from "./handlers/isoHandlers.js";
import { registerDialogHandlers } from "./handlers/dialogHandlers.js";
import { cleanupLeftovers } from "./utils/helpers.js";
import { exec } from "child_process";
import util from "util";
import { WIMLIB_PATH } from "./utils/paths.js";

const execPromise = util.promisify(exec);

app.setName("CrossBoot");

// Fix wimlib permissions on app startup
async function fixWimlibPermissions() {
  try {
    console.log("=".repeat(60));
    console.log("🔧 WIMLIB PERMISSION FIX");
    console.log("=".repeat(60));
    console.log(`📂 Wimlib Path: ${WIMLIB_PATH}`);

    // Check if file exists
    const { stdout: lsOutput } = await execPromise(
      `ls -la "${WIMLIB_PATH}" 2>&1 || echo "NOT FOUND"`
    );
    console.log(`📋 Current permissions:\n${lsOutput}`);

    // Check for quarantine attribute
    const { stdout: xattrOutput } = await execPromise(
      `xattr "${WIMLIB_PATH}" 2>&1 || echo "No attributes"`
    );
    console.log(`🏷️  Extended attributes:\n${xattrOutput}`);

    // Fix permissions
    console.log("⚙️  Applying chmod +x...");
    await execPromise(`chmod +x "${WIMLIB_PATH}"`);

    // Remove quarantine
    console.log("⚙️  Removing quarantine attribute...");
    await execPromise(
      `xattr -d com.apple.quarantine "${WIMLIB_PATH}" 2>/dev/null || true`
    );

    // Verify
    const { stdout: verifyOutput } = await execPromise(
      `ls -la "${WIMLIB_PATH}"`
    );
    console.log(`✅ After fix:\n${verifyOutput}`);
    console.log("✅ Wimlib permissions fixed successfully");
    console.log("=".repeat(60));
  } catch (err) {
    console.error("❌ Could not fix wimlib permissions:", err.message);
    console.error("Stack:", err.stack);
    console.log("=".repeat(60));
  }
}

app.whenReady().then(async () => {
  await cleanupLeftovers();
  await fixWimlibPermissions();

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
