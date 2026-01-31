import SwiftUI

/// Dropdown selector for USB drives
struct DriveSelectorView: View {
    let drives: [Drive]
    @Binding var selectedDrive: Drive?
    
    var body: some View {
        Menu {
            if drives.isEmpty {
                Text("No USB drives found")
                    .foregroundColor(.secondary)
            } else {
                ForEach(drives) { drive in
                    Button(action: {
                        selectedDrive = drive
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(drive.name)
                                Text("\(drive.sizeFormatted) · \(drive.device)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            if drive.id == selectedDrive?.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                if let drive = selectedDrive {
                    Image(systemName: "externaldrive")
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.name)
                            .font(.headline)
                        Text(drive.sizeFormatted)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Text(drives.isEmpty ? "No USB Drive Found" : "Select a drive")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
        }
        .menuStyle(.borderlessButton)
    }
}

#Preview("With Drives") {
    DriveSelectorView(
        drives: [
            Drive(id: "disk2", device: "/dev/disk2", name: "SanDisk Ultra", size: 32_000_000_000),
            Drive(id: "disk3", device: "/dev/disk3", name: "Kingston DataTraveler", size: 16_000_000_000)
        ],
        selectedDrive: .constant(Drive(id: "disk2", device: "/dev/disk2", name: "SanDisk Ultra", size: 32_000_000_000))
    )
    .padding()
    .frame(width: 400)
}

#Preview("Empty") {
    DriveSelectorView(
        drives: [],
        selectedDrive: .constant(nil)
    )
    .padding()
    .frame(width: 400)
}
