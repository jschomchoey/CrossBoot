import { useState } from "react";

function App() {
  const [drives, setDrives] = useState([]);
  const [selectedDisk, setSelectedDisk] = useState("");

  const handleScan = async () => {
    const list = await window.electronAPI.getDisks();
    setDrives(list);

    // เพิ่มตรงนี้: ถ้าเจอ Drive อย่างน้อย 1 ตัว ให้เลือกตัวแรกทันที
    if (list.length > 0) {
      setSelectedDisk(list[0].device);
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
          {/* ซ่อน Option นี้ถ้ามีข้อมูลแล้ว หรือจะเอาออกไปเลยก็ได้ถ้าต้องการให้บังคับเลือกเสมอ */}
          {drives.length === 0 && (
            <option value="" disabled>
              -- No USB Found --
            </option>
          )}

          {drives.map((drive, index) => (
            <option key={index} value={drive.device}>
              {drive.description} ({drive.size})
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}

export default App;
