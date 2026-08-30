import Foundation
import IOKit.pwr_mgt

/// Manages IOKit power assertions to prevent system sleep during long-running operations
actor PowerAssertionManager {
    static let shared = PowerAssertionManager()
    
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isActive = false
    
    private init() {}
    
    /// Create a power assertion to prevent idle sleep and display sleep
    /// - Parameter reason: Human-readable reason for the assertion (shown in pmset -g assertions)
    /// - Throws: PowerAssertionError if creation fails
    func createAssertion(reason: String = "Creating bootable USB drive") throws {
        guard !isActive else {
            // Already have an active assertion, don't create another
            return
        }
        
        let assertionName = reason as CFString
        let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName,
            &assertionID
        )
        
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.creationFailed(result)
        }
        
        isActive = true
        Log.power.debug("Power assertion created (ID: \(self.assertionID))")
    }
    
    /// Release the active power assertion
    func releaseAssertion() {
        guard isActive else {
            // No active assertion to release
            return
        }
        
        let result = IOPMAssertionRelease(assertionID)
        
        if result == kIOReturnSuccess {
            Log.power.debug("Power assertion released (ID: \(self.assertionID))")
        } else {
            Log.power.error("Failed to release power assertion (ID: \(self.assertionID)): \(result)")
        }
        
        isActive = false
        assertionID = IOPMAssertionID(0)
    }
    }

enum PowerAssertionError: LocalizedError {
    case creationFailed(IOReturn)
    
    var errorDescription: String? {
        switch self {
        case .creationFailed(let code):
            return "Failed to create power assertion (IOReturn: \(code))"
        }
    }
}
