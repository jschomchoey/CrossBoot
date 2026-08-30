import SwiftUI

/// The destination picker, rendered as a labelled Form row.
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
        Picker("Drive", selection: selection) {
            if drives.isEmpty {
                Text("No USB drive found")
                    .tag("")
            } else {
                Text("Select a drive…")
                    .tag("")

                ForEach(drives) { drive in
                    Text("\(drive.name) (\(drive.sizeFormatted))")
                        .tag(drive.id)
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(drives.isEmpty)
    }
}

#Preview("With Drives") {
    Form {
        DriveSelectorView(
            drives: [
                Drive(id: "disk2", device: "/dev/disk2", name: "SanDisk Ultra", size: 32_000_000_000),
                Drive(id: "disk3", device: "/dev/disk3", name: "Kingston DataTraveler", size: 16_000_000_000)
            ],
            selectedDrive: .constant(Drive(id: "disk2", device: "/dev/disk2", name: "SanDisk Ultra", size: 32_000_000_000))
        )
    }
    .formStyle(.grouped)
    .frame(width: 400)
}

#Preview("Empty") {
    Form {
        DriveSelectorView(drives: [], selectedDrive: .constant(nil))
    }
    .formStyle(.grouped)
    .frame(width: 400)
}
