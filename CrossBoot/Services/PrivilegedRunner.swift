import Foundation

// Runs the one part of a macOS run that needs root: Apple's createinstallmedia,
// and the installer step that has to precede it.
//
// The app is not signed with a Developer ID, so SMAppService and SMJobBless -
// which install a privileged helper - cannot be used, and
// AuthorizationExecuteWithPrivileges is long gone from the SDK. That leaves one
// authorization prompt per run, raised through osascript.
//
// Nothing the user chose is ever spliced into script text. Paths reach
// AppleScript as `on run argv` items and are wrapped in `quoted form of` at its
// runtime, so a volume called `a"b $(rm -rf ~)` is passed through verbatim - the
// same guarantee ShellHelper gives the unprivileged commands.
actor PrivilegedRunner {
    static let shared = PrivilegedRunner()

    private static let osascript = "/usr/bin/osascript"

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

    // Streams the whole accumulated output so far on every update. The tools
    // write progress as dots on one unterminated line, so there is no line to
    // wait for, and re-reading a log of a few kilobytes costs nothing.
    func createInstallMedia(
        _ request: Request,
        onOutput: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let workDirectory = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let scriptURL = workDirectory.appendingPathComponent("run.sh")
        let logURL = workDirectory.appendingPathComponent("run.log")
        let cancelURL = workDirectory.appendingPathComponent("cancel")

        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let arguments = Self.arguments(
            for: request,
            script: scriptURL,
            log: logURL,
            cancel: cancelURL
        )

        let tail = Task { await Self.tail(logURL, onOutput: onOutput) }
        defer { tail.cancel() }

        do {
            _ = try await withTaskCancellationHandler {
                try await ShellHelper.run(Self.osascript, arguments)
            } onCancel: {
                // The privileged step runs as root and cannot be signalled from
                // here, so it polls for this file and ends itself.
                FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
            }
        } catch {
            // Give the tail a last pass so the failure the log explains has
            // reached the UI before this throws.
            await Self.emit(logURL, onOutput: onOutput)

            if FileManager.default.fileExists(atPath: cancelURL.path) {
                throw CancellationError()
            }

            throw Self.failure(error, log: logURL)
        }

        await Self.emit(logURL, onOutput: onOutput)
    }

    // Everything after "-e" and the script text is argv for `on run`, in the
    // order the shell script reads its positional parameters. Kept separate so
    // the ordering can be checked without raising an authorization prompt.
    static func arguments(
        for request: Request,
        script: URL,
        log: URL,
        cancel: URL
    ) -> [String] {
        [
            "-e", appleScript,
            script.path,
            log.path,
            cancel.path,
            request.preparation.kind,
            request.preparation.source,
            request.applicationURL.path,
            request.device,
            request.volumeName,
            String(request.driveSizeBytes),
            request.removesPreparedInstaller ? "yes" : "no"
        ]
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
        let reported = error.localizedDescription

        // osascript reports a dismissed authorization dialog as -128, which is a
        // deliberate choice rather than something that went wrong.
        if reported.contains("User canceled") || reported.contains("-128") {
            return PrivilegedError.authorizationRefused
        }

        let detail = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " · ")

        return PrivilegedError.stepFailed(detail.isEmpty ? reported : detail)
    }

    // MARK: - Scripts

    // Builds one shell command out of argv and runs it as root. Every item is
    // quoted by AppleScript itself, so no argument can become code.
    private static let appleScript = #"""
    on run argv
        set command to quoted form of (item 1 of argv)
        repeat with index from 2 to (count of argv)
            set command to command & " " & quoted form of (item index of argv)
        end repeat
        do shell script command with administrator privileges
    end run
    """#

    // The privileged step itself. Values arrive as shell variables and are only
    // ever expanded as arguments, never concatenated into commands.
    static let script = #"""
    #!/bin/sh
    # CrossBoot privileged step. See PrivilegedRunner.swift.
    set -u

    LOG="$1"
    CANCEL="$2"
    KIND="$3"
    SOURCE="$4"
    APP="$5"
    DEVICE="$6"
    VOLUME="$7"
    EXPECTED_SIZE="$8"
    CLEANUP="$9"

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
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRefused:
            return "Writing a macOS installer needs an administrator password. Nothing was erased."
        case .stepFailed(let detail):
            return detail
        }
    }
}
