import { useState, useEffect } from "react";

function App() {
  const [drives, setDrives] = useState([]);
  const [selectedDisk, setSelectedDisk] = useState("");
  const [isoPath, setIsoPath] = useState("");

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
      setIsoPath(path); // ได้ path จริง เช่น /Users/name/Downloads/windows.iso
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
    </div>
  );
}

export default App;
