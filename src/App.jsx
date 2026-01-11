import { useState, useEffect, useRef } from "react";
import DriveSelector from "./components/DriveSelector";
import windowsImage from "./assets/images/windows.jpg";
import "./styles/main.scss";

function App() {
  const [drives, setDrives] = useState([]);
  const [selectedDisk, setSelectedDisk] = useState("");
  const [isoPath, setIsoPath] = useState("");
  const [isoName, setIsoName] = useState("");
  const [isoSize, setIsoSize] = useState("");
  const [bypassRequirements, setBypassRequirements] = useState(false);
  const [bypassOnlineAccount, setBypassOnlineAccount] = useState(false);

  const [status, setStatus] = useState("");
  const [isProcessing, setIsProcessing] = useState(false);
  const [currentFile, setCurrentFile] = useState("");
  const [totalProgress, setTotalProgress] = useState(0);
  const [isDragging, setIsDragging] = useState(false);
  const hasSplitRef = useRef(false);

  useEffect(() => {
    handleScan();

    // const scanInterval = setInterval(() => {
    //   handleScan();
    // }, 2000);

    const removeListener = window.electronAPI.onProgress((data) => {
      let calculated = 0;

      if (data.stage === "split") {
        hasSplitRef.current = true;
        // Split: 5% -> 15%
        calculated = 5 + data.percent * 0.1;
        setStatus(`Splitting WIM file... ${data.percent}%`);
      } else if (data.stage === "copy") {
        if (hasSplitRef.current) {
          // Split: 15% -> 99%
          calculated = 15 + data.percent * 0.84;
        } else {
          // Split: 5% -> 99%
          calculated = 5 + data.percent * 0.94;
        }

        setStatus(`Copying files... ${data.percent}%`);
        setCurrentFile(data.currentFile);
      }

      setTotalProgress(parseFloat(calculated.toFixed(2)));
    });

    return () => {
      // clearInterval(scanInterval);
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
    const result = await window.electronAPI.selectIso();
    if (result) {
      // Support both old format (string) and new format (object)
      if (typeof result === "string") {
        setIsoPath(result);
        setIsoName("");
        setIsoSize("");
      } else {
        setIsoPath(result.path);
        setIsoName(result.name || "");
        setIsoSize(result.size || "");
      }
    }
  };

  const handleDragOver = (e) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragging(true);
  };

  const handleDragLeave = (e) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragging(false);
  };

  const handleDrop = async (e) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragging(false);

    const files = e.dataTransfer.files;
    if (files && files.length > 0) {
      const file = files[0];
      if (file.name.toLowerCase().endsWith(".iso")) {
        // Get file stats via Electron API
        const result = await window.electronAPI.getFileInfo(file.path);
        if (result) {
          setIsoPath(result.path);
          setIsoName(result.name || "");
          setIsoSize(result.size || "");
        }
      } else {
        alert("Please select an ISO file");
      }
    }
  };

  const handleStart = async () => {
    if (!selectedDisk) return alert("Select USB");
    if (!isoPath) return alert("Select ISO");

    const targetDrive = drives.find((d) => d.device === selectedDisk);
    const driveName = targetDrive ? targetDrive.description : selectedDisk;

    if (!window.confirm(`Erase Everything on "${driveName}"?`)) return;

    setIsProcessing(true);
    setCurrentFile("");

    setTotalProgress(0);
    hasSplitRef.current = false;

    try {
      // Step 1: Format
      setStatus("Formatting USB...");
      setTotalProgress(2);
      const formatRes = await window.electronAPI.formatUsb(selectedDisk);
      if (!formatRes.success) throw new Error(formatRes.message);
      setTotalProgress(5);

      // Step 2: Prepare ISO
      setStatus("Analyzing ISO and Checking WIM size...");
      const isoRes = await window.electronAPI.prepareIso(isoPath);
      if (!isoRes.success) throw new Error(isoRes.message);

      // Step 3: Copy
      setStatus("Starting file copy...");
      const copyRes = await window.electronAPI.copyToUsb({
        isoMountPoint: isoRes.mountPoint,
        usbDevice: selectedDisk,
        isoAction: isoRes.action,
        tempDir: isoRes.tempDir,
        bypassRequirements,
        bypassOnlineAccount,
      });

      if (copyRes.success) {
        setStatus("Done. USB is ready.");
        setTotalProgress(100);
        await window.electronAPI.showDialog({
          type: "info",
          title: "Success",
          message: "Bootable USB Created Successfully.",
        });
      } else {
        await window.electronAPI.showDialog({
          type: "error",
          title: "Error",
          message: copyRes.message,
        });
      }
    } catch (error) {
      setStatus(`Error: ${error.message}`);
    } finally {
      setIsProcessing(false);
      setCurrentFile("");
    }
  };

  return (
    <div className="safe-margin">
      <div className="app-wrapper">
        <div
          className={`iso-drop-zone ${isDragging ? "dragging" : ""} ${
            isoPath ? "has-file" : ""
          }`}
          onDragOver={handleDragOver}
          onDragLeave={handleDragLeave}
          onDrop={handleDrop}
          onClick={handleSelectIso}
        >
          {isoPath ? (
            <div className="iso-info">
              <img className="iso-image" src={windowsImage} alt="" />
              <div>
                <p className="iso-name">{isoName || isoPath}</p>
                {isoSize && <p className="iso-size">{isoSize}</p>}
                {/* <p className="iso-path">{isoPath}</p> */}
              </div>
            </div>
          ) : (
            <div className="iso-placeholder">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="icon icon-tabler icons-tabler-outline icon-tabler-plus"
              >
                <path stroke="none" d="M0 0h24v24H0z" fill="none" />
                <path d="M12 5l0 14" />
                <path d="M5 12l14 0" />
              </svg>
              <p>Select an ISO file or drag it here</p>
            </div>
          )}
        </div>
        <div className="destination-disk">
          <div className="destination-disk-wrapper">
            <div className="destination-disk-header">
              <p className="text-bold">Destination Disk</p>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="icon icon-tabler icons-tabler-outline icon-tabler-reload"
                onClick={handleScan}
              >
                <path stroke="none" d="M0 0h24v24H0z" fill="none" />
                <path d="M19.933 13.041a8 8 0 1 1 -9.925 -8.788c3.899 -1 7.935 1.007 9.425 4.747" />
                <path d="M20 4v5h-5" />
              </svg>
            </div>

            <DriveSelector
              drives={drives}
              selectedDrive={selectedDisk}
              onSelectDrive={setSelectedDisk}
            />
          </div>
        </div>
        <div className="mb-3">
          <p className="text-bold mb-1">Advanced Options</p>
          <div className="custom-checkbox">
            <input
              type="checkbox"
              name="bypassRequirements"
              id="bypass-requirements"
              checked={bypassRequirements}
              onChange={(e) => setBypassRequirements(e.target.checked)}
              disabled={isProcessing}
            />
            <label htmlFor="bypass-requirements">
              Bypass Windows 11 Requirements.
            </label>
          </div>
          <div className="custom-checkbox">
            <input
              type="checkbox"
              name="bypassOnlineAccount"
              id="bypass-online-account"
              checked={bypassOnlineAccount}
              onChange={(e) => setBypassOnlineAccount(e.target.checked)}
              disabled={isProcessing}
            />
            <label htmlFor="bypass-online-account">
              Bypass Online Account.
            </label>
          </div>
        </div>

        <button
          className="btn btn-primary mb-2"
          onClick={handleStart}
          disabled={isProcessing || !isoPath || !selectedDisk}
        >
          Create Bootable Drive
        </button>
        <div className="progress">
          <div className="progress-bar mb-2">
            <div
              className="progress-bar-inner"
              style={{
                width: `${totalProgress}%`,
              }}
            ></div>
          </div>
          <div className="status">
            <p>Status: {status || "Ready"}</p>
            <p>Total: {totalProgress}%</p>
          </div>

          {/* {isProcessing && currentFile && (
            <p className="status-current">Writing: {currentFile}</p>
          )} */}
        </div>
      </div>
    </div>
  );
}

export default App;
