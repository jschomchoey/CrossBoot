import drivelist from "drivelist";
import fs from "fs/promises";
import path from "path";
import os from "os";

/**
 * Find USB mount point from device path
 * @param {string} devicePath - Device path (e.g., /dev/disk2)
 * @returns {Promise<string>} Mount point path
 */
export async function getUsbMountPoint(devicePath) {
  await new Promise((r) => setTimeout(r, 3000));

  const drives = await drivelist.list();
  const drive = drives.find((d) => d.device === devicePath);

  if (drive && drive.mountpoints.length > 0) {
    return drive.mountpoints[0].path;
  }
  throw new Error(
    "Could not find USB mount point. Please try re-inserting the USB."
  );
}

/**
 * Recursively scan all files in a directory
 * @param {string} dir - Directory path to scan
 * @returns {Promise<Array<{path: string, size: number}>>} Array of file objects
 */
export async function getAllFiles(dir) {
  let results = [];
  const list = await fs.readdir(dir);
  for (const file of list) {
    const filePath = path.join(dir, file);
    const stat = await fs.stat(filePath);
    if (stat && stat.isDirectory()) {
      results = results.concat(await getAllFiles(filePath));
    } else {
      results.push({ path: filePath, size: stat.size });
    }
  }
  return results;
}

/**
 * Cleanup leftover temp directories from previous runs
 */
export async function cleanupLeftovers() {
  const tempBase = os.tmpdir();
  try {
    const files = await fs.readdir(tempBase);
    const targets = files.filter((name) => name.startsWith("crossboot-"));

    for (const dir of targets) {
      const fullPath = path.join(tempBase, dir);
      console.log(`Cleaning leftover: ${fullPath}`);
      await fs.rm(fullPath, { recursive: true, force: true }).catch(() => {});
    }
  } catch (error) {
    console.error("Cleanup Error:", error);
  }
}

/**
 * Get file information including size and name
 * @param {string} filePath - Path to file
 * @returns {Promise<{path: string, name: string, size: string, sizeBytes: number}>}
 */
export async function getFileInfo(filePath) {
  const stats = await fs.stat(filePath);
  const sizeInBytes = stats.size;
  const sizeInGB = (sizeInBytes / (1024 * 1024 * 1024)).toFixed(2);
  const fileName = path.basename(filePath);

  return {
    path: filePath,
    name: fileName,
    size: `${sizeInGB} GB`,
    sizeBytes: sizeInBytes,
  };
}
