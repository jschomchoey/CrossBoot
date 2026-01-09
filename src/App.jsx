import { useState, useEffect, useRef } from "react";

function App() {
  const [drives, setDrives] = useState([]);
  const [selectedDisk, setSelectedDisk] = useState("");
  const [isoPath, setIsoPath] = useState("");

  const [status, setStatus] = useState("");
  const [isProcessing, setIsProcessing] = useState(false);

  const [currentFile, setCurrentFile] = useState("");

  const [totalProgress, setTotalProgress] = useState(0);
  const hasSplitRef = useRef(false);

  useEffect(() => {
    handleScan();

    const removeListener = window.electronAPI.onProgress((data) => {
      let calculated = 0;

      if (data.stage === "split") {
        hasSplitRef.current = true; // Split
        // Split: 5% -> 15%
        calculated = 5 + data.percent * 0.1;
        setStatus(`Splitting WIM file... ${data.percent}%`);
      } else if (data.stage === "copy") {
        if (hasSplitRef.current) {
          // Split: 15% -> 100%
          calculated = 15 + data.percent * 0.85;
        } else {
          // Split: 5% -> 100%
          calculated = 5 + data.percent * 0.95;
        }

        setStatus(`Copying files... ${data.percent}%`);
        setCurrentFile(data.currentFile);
      }

      setTotalProgress(calculated);
    });

    return () => {
      window.electronAPI.removeProgressListeners();
    };
  }, []);

  const handleScan = async () => {
    const list = await window.electronAPI.getDisks();
    setDrives(list);

    if (list.length > 0) {
      setSelectedDisk(list[0].device);
    }
  };

  const handleSelectIso = async () => {
    const path = await window.electronAPI.selectIso();
    if (path) {
      setIsoPath(path);
    }
  };

  const handleStart = async () => {
    if (!selectedDisk) return alert("Select USB");
    if (!isoPath) return alert("Select ISO");

    const targetDrive = drives.find((d) => d.device === selectedDisk);
    const driveName = targetDrive ? targetDrive.description : selectedDisk;

    if (!window.confirm(`ERASE Everything on "${driveName}"?`)) return;

    setIsProcessing(true);
    setProgress(0);
    setCurrentFile("");

    setTotalProgress(0);
    hasSplitRef.current = false;

    try {
      // Step 1: Format
      setCurrentAction("format");
      setStatus("Formatting USB...");
      setTotalProgress(2);
      const formatRes = await window.electronAPI.formatUsb(selectedDisk);
      if (!formatRes.success) throw new Error(formatRes.message);
      setTotalProgress(5);

      // Step 2: Prepare ISO
      setCurrentAction("analyze");
      setStatus("Analyzing ISO and Checking WIM size...");
      const isoRes = await window.electronAPI.prepareIso(isoPath);
      if (!isoRes.success) throw new Error(isoRes.message);

      // Step 3: Copy
      setCurrentAction("copy");
      setStatus("Starting file copy...");
      const copyRes = await window.electronAPI.copyToUsb({
        isoMountPoint: isoRes.mountPoint,
        usbDevice: selectedDisk,
        isoAction: isoRes.action,
        tempDir: isoRes.tempDir,
      });

      if (copyRes.success) {
        setStatus("DONE! USB is ready.");
        setTotalProgress(100);
        alert("Success!");
      } else {
        throw new Error(copyRes.message);
      }
    } catch (error) {
      console.error(error);
      setStatus(`Error: ${error.message}`);
    } finally {
      setIsProcessing(false);
      setCurrentFile("");
    }
  };

  return (
    <div>
      <div>
        <button onClick={handleScan}>Scan USB</button>

        <select
          value={selectedDisk}
          onChange={(e) => setSelectedDisk(e.target.value)}
        >
          {drives.length === 0 && (
            <option value="" disabled>
              -- No USB Found --
            </option>
          )}

          {drives.map((drive, index) => (
            <option key={index} value={drive.device}>
              {drive.description} (
              {drive.size ? `${(drive.size / 1e9).toFixed(2)} GB` : "Unknown"})
            </option>
          ))}
        </select>
      </div>
      <div>
        <button onClick={handleSelectIso}>Select ISO</button>
        <span>ISO Path: {isoPath || "No ISO Selected"}</span>
      </div>
      <div>
        <button
          onClick={handleStart}
          disabled={isProcessing || !isoPath || !selectedDisk}
        >
          START
        </button>
        <div
          style={{
            width: "100%",
            height: "5px",
            border: "1px solid black",
            borderRadius: "5px",
            marginTop: "5px",
          }}
        >
          <div
            style={{
              width: `${totalProgress}%`,
              height: "100%",
              backgroundColor: "blue",
              transition: "width 0.2s ease",
            }}
          ></div>
        </div>
        <span>Status: {status}</span>
        {isProcessing && currentFile && <div>Writing: {currentFile}</div>}
      </div>
    </div>
  );
}

export default App;
