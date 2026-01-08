import { useState, useEffect } from "react";

function App() {
  const [drives, setDrives] = useState([]);
  const [selectedDisk, setSelectedDisk] = useState("");
  const [isoPath, setIsoPath] = useState("");

  const [status, setStatus] = useState("");
  const [isProcessing, setIsProcessing] = useState(false);

  useEffect(() => {
    handleScan();
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
    if (!selectedDisk) return alert("Please select a USB drive");
    if (!isoPath) return alert("Please select an ISO file");

    const targetDrive = drives.find((d) => d.device === selectedDisk);
    const driveName = targetDrive ? targetDrive.description : selectedDisk;

    const confirm = window.confirm(
      `WARNING: All data on "${driveName}" will be erased. Continue?`
    );
    if (!confirm) return;

    setIsProcessing(true);
    setStatus(`Formatting "${driveName}"...`);

    try {
      const result = await window.electronAPI.formatUsb(selectedDisk);

      if (result.success) {
        setStatus("Format Complete");
      } else {
        setStatus(`Error: ${result.message}`);
      }
    } catch (error) {
      setStatus("An unexpected error occurred.");
    } finally {
      setIsProcessing(false);
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
        <span>Status: {status}</span>
      </div>
    </div>
  );
}

export default App;
