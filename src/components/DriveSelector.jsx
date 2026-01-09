import { useState, useRef, useEffect } from "react";
import diskIcon from "../assets/images/disk-external.png";

function DriveSelector({ drives, selectedDrive, onSelectDrive }) {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef(null);

  // Helper function
  const formatSize = (size) =>
    size ? `${(size / 1e9).toFixed(2)} GB` : "Unknown";
  const selectedData = drives.find((d) => d.device === selectedDrive);

  // Click outside
  useEffect(() => {
    const handleClick = (e) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target))
        setIsOpen(false);
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, []);

  const DriveItem = ({ drive, onClick, isActive }) => (
    <div onClick={onClick} className="drive-item">
      <img className="usb-dropdown-option" src={diskIcon} alt="USB" />
      <div>
        <p>{drive.description}</p>
        <div className="usb-detail">
          <span>
            {formatSize(drive.size)} · {drive.device}
          </span>
        </div>
      </div>
      {/* {isActive && <span>✓</span>} */}
    </div>
  );

  const SelectedDisplay = ({ drive }) => (
    <div className="dropdown-header">
      <div className="usb-selected-display">
        <img className="usb-dropdown-selected" src={diskIcon} alt="USB" />
        <div className="usb-detail">
          <p className="text-bold">{drive.description}</p>
          <span>{formatSize(drive.size)}</span>
        </div>
      </div>
      <p>
        {isOpen ? (
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
            class="icon icon-tabler icons-tabler-outline icon-tabler-selector"
          >
            <path stroke="none" d="M0 0h24v24H0z" fill="none" />
            <path d="M8 9l4 -4l4 4" />
            <path d="M16 15l-4 4l-4 -4" />
          </svg>
        ) : (
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
            className="icon icon-tabler icons-tabler-outline icon-tabler-selector"
          >
            <path stroke="none" d="M0 0h24v24H0z" fill="none" />
            <path d="M8 9l4 -4l4 4" />
            <path d="M16 15l-4 4l-4 -4" />
          </svg>
        )}
      </p>
    </div>
  );

  return (
    <div className="drive-selector" ref={dropdownRef}>
      <div
        className="dropdown-header-nodevice"
        onClick={() => setIsOpen(!isOpen)}
      >
        {drives.length === 0 ? (
          <div className="nodevice">
            <p>No USB Drive Found</p>
          </div>
        ) : selectedData ? (
          <SelectedDisplay drive={selectedData} />
        ) : (
          <p>Select a drive</p>
        )}
      </div>

      {isOpen && drives.length > 0 && (
        <div className="dropdown-list">
          {drives.map((drive) => (
            <DriveItem
              key={drive.device}
              drive={drive}
              isActive={drive.device === selectedDrive}
              onClick={() => {
                onSelectDrive(drive.device);
                setIsOpen(false);
              }}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export default DriveSelector;
