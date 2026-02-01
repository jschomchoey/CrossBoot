import SwiftUI

struct DriveSelectorView: View {
    let drives: [Drive]
    @Binding var selectedDrive: Drive?
    
    private var selection: Binding<String> {
        Binding(
            get: { selectedDrive?.id ?? "" },
            set: { newId in
                selectedDrive = drives.first { $0.id == newId }
            }
        )
    }
    
    var body: some View {
        Picker("", selection: selection) {
            if drives.isEmpty {
                Text("No USB Drive Found")
                    .tag("")
            } else {
                Text("Select a drive...")
                    .tag("")
                
                ForEach(drives) { drive in
                    Text("\(drive.name) (\(drive.sizeFormatted))")
                        .tag(drive.id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
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
