import Foundation
import TesseraKit

/// zsh integration for terminal tiles, done the way VS Code and Ghostty do it: tiles start zsh with
/// ZDOTDIR pointing at a small shim that sources the user's own startup files in the normal order,
/// then adds two hooks — report each command line as typed (so `codex-work` is known even though
/// it execs `codex`) and report returning to the prompt. The user's files are never modified.
enum ShellIntegration {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tessera/shell-integration/zsh")
    }

    /// Wraps one user startup file: switch ZDOTDIR to the user's, source it, switch back.
    private static func shim(_ name: String, extra: String = "", final: Bool = false) -> String {
        """
        # Tessera shell integration — sources your own \(name), then continues. Regenerated on launch.
        # The tile's secret stays a private shell variable: programs started from this shell never see it.
        if [[ -n "$TESSERA_NONCE" ]]; then typeset -g __tessera_nonce="$TESSERA_NONCE"; unset TESSERA_NONCE; fi
        TESSERA_ZDOTDIR="${TESSERA_ZDOTDIR:-$ZDOTDIR}"
        ZDOTDIR="${TESSERA_USER_ZDOTDIR:-$HOME}"
        # /etc/zshrc derives HISTFILE from ZDOTDIR while it points here; keep history in the user's file.
        [[ "$HISTFILE" == "$TESSERA_ZDOTDIR/.zsh_history" ]] && HISTFILE="$ZDOTDIR/.zsh_history"
        [[ -f "$ZDOTDIR/\(name)" ]] && source "$ZDOTDIR/\(name)"
        TESSERA_USER_ZDOTDIR="$ZDOTDIR"
        \(extra)
        \(final ? "ZDOTDIR=\"$TESSERA_USER_ZDOTDIR\"" : "ZDOTDIR=\"$TESSERA_ZDOTDIR\"")

        """
    }

    private static let hooks = """
    if [[ -o interactive && -z "$TESSERA_HOOKS" ]]; then
      TESSERA_HOOKS=1
      __tessera_preexec() {
        # $1 is the line as typed; $3 has aliases expanded (so `cx` → `codex-work` is recognisable).
        printf '\\033]\(ShellEvent.oscCode);cmd;%s;%s;%s\\007' "$__tessera_nonce" "$(print -rn -- "$1" | /usr/bin/base64)" "$(print -rn -- "$3" | /usr/bin/base64)"
      }
      __tessera_precmd() {
        local s=$?
        printf '\\033]\(ShellEvent.oscCode);done;%s;%s\\007' "$__tessera_nonce" "$s"
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook preexec __tessera_preexec
      add-zsh-hook precmd __tessera_precmd
    fi
    """

    /// Writes the shim files (only when their contents changed). Returns the ZDOTDIR to use, or nil.
    @discardableResult
    static func install() -> URL? {
        let dir = directory
        let files: [String: String] = [
            ".zshenv": shim(".zshenv"),
            ".zprofile": shim(".zprofile"),
            ".zshrc": shim(".zshrc", extra: hooks),
            ".zlogin": shim(".zlogin", final: true)
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, content) in files {
                let url = dir.appendingPathComponent(name)
                if (try? String(contentsOf: url, encoding: .utf8)) != content {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            return dir
        } catch {
            return nil
        }
    }

    static let installed: URL? = install()

    static func isZsh(_ shell: String) -> Bool { (shell as NSString).lastPathComponent == "zsh" }
    static func isFish(_ shell: String) -> Bool { LaunchScript.dialect(forShell: shell) == .fish }

    /// fish loads its own config normally; Tessera's hooks come in via `--init-command`.
    static let fishHooks = """
    function __tessera_preexec --on-event fish_preexec
        printf '\\e]\(ShellEvent.oscCode);cmd;%s;%s\\a' $__tessera_nonce (printf '%s' $argv[1] | /usr/bin/base64)
    end
    function __tessera_postexec --on-event fish_postexec
        printf '\\e]\(ShellEvent.oscCode);done;%s;%s\\a' $__tessera_nonce $status
    end
    """

    static let fishHooksFile: URL? = {
        let url = directory.deletingLastPathComponent().appendingPathComponent("fish/tessera.fish")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != fishHooks {
                try fishHooks.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            return nil
        }
    }()

    /// Arguments for an interactive login shell in a tile (fish gets its hooks here). tcsh and csh
    /// take `-l` only on its own; shells Tessera doesn't know get no flags rather than rejected ones.
    static func interactiveArguments(_ shell: String, nonce: String) -> [String] {
        if isFish(shell), let hooks = fishHooksFile {
            // fish gets its secret as a private global, never through the environment.
            return ["-l", "-i", "-C", "set -g __tessera_nonce \(nonce); source \(ShellWords.join([hooks.path]))"]
        }
        if LaunchScript.dialect(forShell: shell) != nil { return ["-l", "-i"] }
        return ["tcsh", "csh"].contains((shell as NSString).lastPathComponent) ? ["-l"] : []
    }

    /// Environment additions for a tile's shell.
    static func environment(shell: String, base: [String: String], nonce: String) -> [String: String] {
        guard isZsh(shell), let dir = installed else { return [:] }
        return ["ZDOTDIR": dir.path, "TESSERA_USER_ZDOTDIR": base["ZDOTDIR"] ?? NSHomeDirectory(),
                "TESSERA_ZDOTDIR": dir.path, "TESSERA_NONCE": nonce]
    }

    /// The `exec` that follows a launched command, re-entering an integrated shell afterwards.
    static func followUpShell(_ shell: String, nonce: String) -> String {
        if isZsh(shell), let dir = installed {
            return "exec env ZDOTDIR=\(ShellWords.join([dir.path])) TESSERA_NONCE=\(nonce) \(shell) -l -i"
        }
        return "exec " + ShellWords.join([shell] + interactiveArguments(shell, nonce: nonce))
    }
}

/// The user's login shell, for tiles and for finding tools on the PATH its startup files set up.
enum LoginShell {
    static var path: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// What runs Tessera's scripts for `shell`: the shell itself when it speaks POSIX sh or fish, else zsh.
    static func scriptShell(for shell: String) -> String {
        LaunchScript.dialect(forShell: shell) == nil ? "/bin/zsh" : shell
    }

    /// Runs `script` in an interactive login shell and returns what it printed, or nil if it
    /// couldn't run or was stopped after `timeout` (a startup file waiting on something). Startup
    /// files may print too, so scripts tag the lines they mean.
    static func run(_ script: String, timeout: TimeInterval = 20) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scriptShell(for: path))
        p.arguments = ["-l", "-i", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Interactive shells ignore SIGTERM, and whatever a startup file started holds the output
        // open too: stop the whole process group (Process starts the shell as its leader).
        let pid = p.processIdentifier
        let killer = DispatchWorkItem { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
    }

    /// The values of lines `script` printed as `@<tag> <value>`.
    static func tagged(_ tag: String, in output: String) -> [String] {
        output.split(separator: "\n").compactMap { $0.hasPrefix("@\(tag) ") ? String($0.dropFirst(tag.count + 2)) : nil }
    }
}
