import Foundation
import CoreServices

// Runs the one part of a macOS run that needs root: Apple's createinstallmedia,
// and the installer step that has to precede it.
//
// The step runs in Terminal, under sudo, and this app only starts it and reads
// what it writes.
//
// createinstallmedia's last step - blessing the drive - is refused by TCC unless
// the process doing it has Full Disk Access, and macOS does not let an app's own
// grant reach a root process raised through the authorization trampoline. That
// is every form of `do shell script with administrator privileges`, whoever
// raises it: the drive is written and then cannot be made bootable. A command
// sudo'd inside Terminal is Terminal's own child, and Terminal is an app the
// user can grant that access to once.
//
// The step checks for that access itself, before anything is erased, so a drive
// is never wiped for a run that could not have finished.
//
// The prompt is raised when the run starts, not when the drive is written: the
// step parks itself on a sentinel file and the app lets it go once the installer
// has been downloaded. Otherwise the password is asked for an hour into a run
// nobody is sitting in front of any more.
//
// Nothing the user chose is ever spliced into script text. Paths reach
// AppleScript as `on run argv` items and are wrapped in `quoted form of` at its
// runtime, so a volume called `a"b $(rm -rf ~)` is passed through verbatim - the
// same guarantee ShellHelper gives the unprivileged commands.
actor PrivilegedRunner {
    static let shared = PrivilegedRunner()

    private init() {}

    // How the installer application is obtained before the drive is written.
    enum Preparation: Equatable {
        // Expand a downloaded InstallAssistant.pkg into /Applications.
        case package(URL)
        // softwareupdate --fetch-full-installer, for a version this Mac is offered.
        case fetch(version: String)
        // The user already has the application; nothing to prepare.
        case application

        var kind: String {
            switch self {
            case .package: return "package"
            case .fetch: return "fetch"
            case .application: return "application"
            }
        }

        var source: String {
            switch self {
            case .package(let url): return url.path
            case .fetch(let version): return version
            case .application: return ""
            }
        }
    }

    struct Request {
        let preparation: Preparation
        let applicationURL: URL
        let device: String
        // Checked again inside the privileged step, immediately before the
        // erase, so a drive swapped after the user picked it cannot be erased.
        let driveSizeBytes: Int64
        let volumeName: String
        // Whether the installer application this step prepared is removed once
        // the drive is written. Never touches one the user already had.
        let removesPreparedInstaller: Bool
    }

    // Raises the authorization prompt, runs `preparing` while the step waits for
    // it, and only then lets the step touch the drive.
    //
    // Output is streamed as the whole accumulated log on every update. The tools
    // write progress as dots on one unterminated line, so there is no line to
    // wait for, and re-reading a log of a few kilobytes costs nothing.
    func createInstallMedia(
        _ request: Request,
        preparing: @escaping @Sendable () async throws -> Void,
        onOutput: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let workDirectory = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let scriptURL = workDirectory.appendingPathComponent("run.sh")
        let logURL = workDirectory.appendingPathComponent("run.log")
        let cancelURL = workDirectory.appendingPathComponent("cancel")
        let readyURL = workDirectory.appendingPathComponent("ready")
        let heartbeatURL = workDirectory.appendingPathComponent("heartbeat")
        let statusURL = workDirectory.appendingPathComponent("status")

        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        FileManager.default.createFile(atPath: heartbeatURL.path, contents: nil)

        let arguments = Self.arguments(
            for: request,
            script: scriptURL,
            log: logURL,
            cancel: cancelURL,
            ready: readyURL,
            heartbeat: heartbeatURL
        )

        let tail = Task { await Self.tail(logURL, onOutput: onOutput) }
        let heartbeat = Task { await Self.beat(heartbeatURL) }
        defer {
            tail.cancel()
            heartbeat.cancel()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await Self.runInTerminal(arguments, status: statusURL)
                    } onCancel: {
                        // The privileged step runs as root and cannot be
                        // signalled from here, so it polls for this file and
                        // ends itself.
                        FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
                    }
                }

                group.addTask {
                    do {
                        try await preparing()
                    } catch {
                        // The step is parked on a file that is never coming.
                        FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
                        throw PreparationFailed(underlying: error)
                    }

                    FileManager.default.createFile(atPath: readyURL.path, contents: nil)
                }

                // Whichever fails first ends the run: a refused password must
                // not leave a download running, and a download that failed must
                // not leave the drive to be erased.
                for try await _ in group {}
            }
        } catch let failure as PreparationFailed {
            await Self.emit(logURL, onOutput: onOutput)

            throw failure.underlying
        } catch {
            // Give the tail a last pass so the failure the log explains has
            // reached the UI before this throws.
            await Self.emit(logURL, onOutput: onOutput)

            // The sentinel is also written when preparation fails, so what the
            // run was asked to do - not the file - is what says this was a stop.
            if Task.isCancelled {
                throw CancellationError()
            }

            throw Self.failure(error, log: logURL)
        }

        await Self.emit(logURL, onOutput: onOutput)
    }

    // Preparation reports its own failures - a download that stopped is not a
    // privileged step that went wrong - so its error is carried out untouched.
    private struct PreparationFailed: Error {
        let underlying: Error
    }

    // What `on run` receives, in the order the shell script reads its positional
    // parameters. Kept separate so the ordering can be checked without raising
    // an authorization prompt.
    static func arguments(
        for request: Request,
        script: URL,
        log: URL,
        cancel: URL,
        ready: URL,
        heartbeat: URL,
        accessProbe: String = accessProbe
    ) -> [String] {
        [
            script.path,
            log.path,
            cancel.path,
            ready.path,
            heartbeat.path,
            accessProbe,
            request.preparation.kind,
            request.preparation.source,
            request.applicationURL.path,
            request.device,
            request.volumeName,
            String(request.driveSizeBytes),
            request.removesPreparedInstaller ? "yes" : "no"
        ]
    }

    // MARK: - Elevation

    // TCC's own database: nothing short of Full Disk Access reads it, so asking
    // whether the step can is the same question as asking whether it will be
    // allowed to finish. Passed in rather than hard-coded in the script so the
    // check itself can be tested against a file that is readable.
    static let accessProbe = "/Library/Application Support/com.apple.TCC/TCC.db"

    // What the step exits with when that access is missing.
    static let accessDenied = 77

    // NSAppleScript is not thread-safe; one queue owns every use of it.
    private static let scripting = DispatchQueue(label: "com.crossboot.privileged-step")

    // Starts the step in Terminal and waits for the status it leaves behind.
    // `do script` returns as soon as Terminal has the command, so the run is
    // followed through the files it writes, the same way its progress is.
    private static func runInTerminal(_ argv: [String], status statusURL: URL) async throws {
        try await tell(Self.terminalScript, [command(argv, status: statusURL)])

        // The window has served its purpose once the step has a status, whatever
        // that status is.
        defer { Task { try? await tell(Self.closeScript, []) } }

        while !Task.isCancelled {
            if let status = Int(
                (try? String(contentsOf: statusURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ) {
                guard status == 0 else { throw StepFailed(status: status) }
                return
            }

            try await Task.sleep(nanoseconds: pollInterval)
        }

        throw CancellationError()
    }

    // One command line for Terminal: sudo, the script, its arguments, and the
    // status the app is waiting for. Every value is quoted the way `quoted form
    // of` quoted it before, so nothing a user chose can become code.
    static func command(_ argv: [String], status statusURL: URL) -> String {
        let step = argv.map(shellQuoted).joined(separator: " ")

        return "clear; /usr/bin/sudo -- \(step); echo $? > \(shellQuoted(statusURL.path))"
    }

    // POSIX quoting: everything inside single quotes is literal, and the only
    // character that cannot appear there is the single quote itself.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tell(_ source: String, _ argv: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            scripting.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: PrivilegedError.stepFailed("The privileged step could not be compiled."))
                    return
                }

                var failure: NSDictionary?
                script.executeAppleEvent(runEvent(argv), error: &failure)

                guard let failure else {
                    continuation.resume()
                    return
                }

                continuation.resume(throwing: ScriptFailure(
                    number: failure[NSAppleScript.errorNumber] as? Int ?? 0,
                    message: failure[NSAppleScript.errorMessage] as? String ?? ""
                ))
            }
        }
    }

    // `on run argv` is reached by sending the script the event AppleScript would
    // have sent it, with the arguments as the event's direct object.
    private static func runEvent(_ argv: [String]) -> NSAppleEventDescriptor {
        let arguments = NSAppleEventDescriptor.list()
        for (index, value) in argv.enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        return event
    }

    // What the step exited with, once Terminal had run it.
    private struct StepFailed: Error {
        let status: Int
    }

    // What AppleScript itself reported, when the command never got that far.
    private struct ScriptFailure: Error {
        let number: Int
        let message: String
    }

    // MARK: - Scratch

    private static func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-privileged-\(UUID().uuidString)")

        // Root writes the log and reads the script back, so neither may sit
        // anywhere another user could substitute them.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        return directory
    }

    // MARK: - Output

    private static let pollInterval: UInt64 = 250_000_000
    // Well inside the two minutes the parked step allows between touches.
    private static let heartbeatInterval: UInt64 = 10_000_000_000

    // Proof that the app is still there. A step parked on the ready file would
    // otherwise sit as root for as long as the machine stayed on.
    private static func beat(_ heartbeatURL: URL) async {
        while !Task.isCancelled {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: heartbeatURL.path
            )
            try? await Task.sleep(nanoseconds: heartbeatInterval)
        }
    }

    private static func tail(
        _ logURL: URL,
        onOutput: @escaping @Sendable @MainActor (String) -> Void
    ) async {
        while !Task.isCancelled {
            await emit(logURL, onOutput: onOutput)
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private static func emit(
        _ logURL: URL,
        onOutput: @escaping @Sendable @MainActor (String) -> Void
    ) async {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        await onOutput(text)
    }

    // MARK: - Failure

    private static func failure(_ error: Error, log logURL: URL) -> Error {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let step = error as? StepFailed
        let script = error as? ScriptFailure

        // The step said so itself, before erasing anything - or createinstallmedia
        // ran into it at the end, which is what TCC does to a bless.
        if step?.status == accessDenied
            || text.contains("CrossBoot: no full disk access")
            || text.contains("bless of the installer disk failed") {
            return PrivilegedError.accessRefused
        }

        // Terminal is what runs the step, and being allowed to drive it is a
        // permission of its own.
        if script?.number == -1743 || script?.number == -600 {
            return PrivilegedError.terminalRefused
        }

        // A dismissed prompt is -128; sudo that never ran the step leaves an
        // empty log behind. Neither is something that went wrong.
        if script?.number == -128 || (step?.status == 1 && text.isEmpty) {
            return PrivilegedError.authorizationRefused
        }

        let reported = script?.message ?? error.localizedDescription

        let detail = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " · ")

        return PrivilegedError.stepFailed(detail.isEmpty ? reported : detail)
    }

    // MARK: - Scripts

    // Hands one command line to Terminal and leaves it there. The window is
    // titled so the user knows which one is asking for their password, and so
    // the app can close it again when the step is over.
    private static let terminalScript = #"""
    on run argv
        tell application "Terminal"
            activate
            set theTab to do script (item 1 of argv)
            set custom title of theTab to "CrossBoot"
        end tell
    end run
    """#

    // Closes the window the step ran in. Best effort: a window the user closed
    // themselves, or kept, is not worth reporting.
    private static let closeScript = #"""
    on run argv
        tell application "Terminal"
            repeat with theWindow in windows
                try
                    if custom title of selected tab of theWindow is "CrossBoot" then close theWindow
                end try
            end repeat
        end tell
    end run
    """#

    // The privileged step itself. Values arrive as shell variables and are only
    // ever expanded as arguments, never concatenated into commands.
    static let script = #"""
    #!/bin/sh
    # CrossBoot privileged step. See PrivilegedRunner.swift.
    set -u

    LOG="$1"; shift
    CANCEL="$1"; shift
    READY="$1"; shift
    HEARTBEAT="$1"; shift
    ACCESS="$1"; shift
    KIND="$1"; shift
    SOURCE="$1"; shift
    APP="$1"; shift
    DEVICE="$1"; shift
    VOLUME="$1"; shift
    EXPECTED_SIZE="$1"; shift
    CLEANUP="$1"

    exec >>"$LOG" 2>&1

    # Every path below is used as an argument, never as code, but this step runs
    # as root and one of its commands removes a directory tree, so a traversal is
    # refused outright rather than relied on to be harmless.
    case "$APP$SOURCE$VOLUME" in
        *..*)
            echo "CrossBoot: refusing a path containing .."
            exit 65
            ;;
    esac

    # createinstallmedia writes to the mounted installer volume as its last step,
    # and TCC refuses that unless whoever runs this has Full Disk Access. Reading
    # TCC's own database asks the same question, and it is asked here - before
    # the drive is erased - rather than found out an hour later.
    if [ ! -r "$ACCESS" ]; then
        echo "CrossBoot: no full disk access"
        exit 77
    fi

    # The password was asked for when the run started, but what this step writes
    # is only downloaded afterwards. Waiting here is what keeps the prompt at the
    # start of a run rather than an hour into one.
    echo "CrossBoot: waiting"
    while [ ! -e "$READY" ]; do
        if [ -e "$CANCEL" ]; then
            echo "CrossBoot: stopped"
            exit 130
        fi

        # The app touches the heartbeat while it works. Nothing else ends this
        # wait if the app is killed, and root must not be left parked here.
        if [ ! -e "$HEARTBEAT" ] || [ -n "$(/usr/bin/find "$HEARTBEAT" -mmin +2)" ]; then
            echo "CrossBoot: the app stopped answering"
            exit 75
        fi

        sleep 1
    done

    # Runs one command in the background so the cancel sentinel can end it.
    # The app runs unprivileged and cannot signal a root process, so stopping
    # has to be handled from in here.
    #
    # A "y" on stdin answers the confirmation createinstallmedia still asks for
    # on some releases; every other tool used here ignores stdin.
    run() {
        printf 'y\n' | "$@" &
        child=$!

        while kill -0 "$child" 2>/dev/null; do
            if [ -e "$CANCEL" ]; then
                kill -TERM "$child" 2>/dev/null
                wait "$child" 2>/dev/null
                echo "CrossBoot: stopped"
                exit 130
            fi
            sleep 1
        done

        wait "$child"
    }

    field() {
        /usr/sbin/diskutil info -plist "$DEVICE" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
    }

    case "$KIND" in
        package)
            echo "CrossBoot: preparing"
            run /usr/sbin/installer -pkg "$SOURCE" -target / || exit $?
            ;;
        fetch)
            echo "CrossBoot: preparing"
            run /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "$SOURCE" || exit $?
            ;;
    esac

    if [ ! -x "$APP/Contents/Resources/createinstallmedia" ]; then
        echo "CrossBoot: no createinstallmedia in $APP"
        exit 66
    fi

    # The drive was checked before the password was asked for, and preparing the
    # installer can take many minutes. Anything could have been unplugged and
    # replaced in between, so it is checked again here - the erase is the step
    # that cannot be taken back.
    if [ "$(field Internal)" != "false" ]; then
        echo "CrossBoot: $DEVICE is not an external drive"
        exit 65
    fi

    if [ "$(field Ejectable)" != "true" ] && [ "$(field Removable)" != "true" ]; then
        echo "CrossBoot: $DEVICE is not a removable drive"
        exit 65
    fi

    if [ "$(field TotalSize)" != "$EXPECTED_SIZE" ]; then
        echo "CrossBoot: $DEVICE is no longer the drive that was chosen"
        exit 65
    fi

    echo "CrossBoot: erasing"
    run /usr/sbin/diskutil eraseDisk JHFS+ "$VOLUME" GPT "$DEVICE" || exit $?

    # A newly erased volume takes a moment to appear, which is why the Windows
    # path retries for its mount point too.
    attempt=0
    while [ ! -d "/Volumes/$VOLUME" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 15 ]; then
            echo "CrossBoot: the erased drive did not mount"
            exit 74
        fi
        sleep 1
    done

    echo "CrossBoot: writing"
    run "$APP/Contents/Resources/createinstallmedia" --volume "/Volumes/$VOLUME" --nointeraction || exit $?

    # Preparing the installer left 12-18 GB in /Applications that the user did
    # not ask to keep. Only a bundle this step created is removed: it has to sit
    # where Apple's own installer puts it and still be a real installer.
    if [ "$CLEANUP" = "yes" ] && [ "$KIND" != "application" ]; then
        case "$APP" in
            '/Applications/Install macOS'*.app)
                if [ -x "$APP/Contents/Resources/createinstallmedia" ]; then
                    echo "CrossBoot: removing the installer"
                    /bin/rm -rf "$APP"
                fi
                ;;
        esac
    fi

    echo "CrossBoot: finished"
    """#
}

enum PrivilegedError: LocalizedError, Equatable {
    case authorizationRefused
    case accessRefused
    case terminalRefused
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRefused:
            return "Writing a macOS installer needs an administrator password. Nothing was erased."
        case .accessRefused:
            return """
            Terminal needs Full Disk Access to make the drive bootable, and macOS does not let \
            CrossBoot lend it its own.

            Switch Terminal on in System Settings > Privacy & Security > Full Disk Access, quit \
            Terminal, and run again. Nothing was erased.
            """
        case .terminalRefused:
            return """
            CrossBoot writes the drive through Terminal and was not allowed to open it.

            Switch Terminal on for CrossBoot in System Settings > Privacy & Security > Automation, \
            and run again. Nothing was erased.
            """
        case .stepFailed(let detail):
            return detail
        }
    }
}
