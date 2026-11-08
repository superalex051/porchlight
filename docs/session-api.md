# Session API, version 1

The contract for apps that drive Porch Light sessions: a remote desktop host, a script, or anything else that needs a screen sized for its client while the desk monitors are off. Callers use the `porchlight` CLI, or the Swift library `PorchLightClient` in this package. The Parsec scripts in `Scripts/parsec/` are callers too.

## 1. What version 1 covers

- `porchlight session start`, `session end`, `session resize`, `session status` and `session watch`, with and without `--json`.
- The status object those commands return (section 3).
- The owner rule (section 7).
- The distributed notification `com.alexluncan.PorchLight.sessionChanged` (section 8).
- The Swift library `PorchLightClient` and the socket messages it sends (sections 9 and 11).

Not part of version 1: `session presets` (text only, no JSON payload), `rescue`, `get`, `set`, `create`, `discard`, `ping`, `quit`.

## 2. The CLI

`porchlight` is `/Applications/PorchLight.app/Contents/Helpers/porchlight`. `Scripts/install.sh --link-cli` links it at `~/.local/bin/porchlight`.

If the app isn't running, a command starts it (`open -g -a /Applications/PorchLight.app`) and waits for it to be ready, unless `--no-launch` is given.

Options, which can go anywhere on the line:

| Option | Meaning |
|---|---|
| `--json` | One line of JSON (below). |
| `--no-launch` | If the app isn't running, fail with `app not running` instead of starting it. |
| `--timeout=<seconds>` | How long to wait for the app, including a launch. 60 by default for session commands. |

**Without `--json`:** the answer on stdout and exit 0, or `Failed. <reason>` on stderr and exit 1. A `warning: <text>` line on stderr can come with a success.

**With `--json`:** exactly one line on stdout per answer, nothing on stderr, and the same exit code as without. The line is an object with these five keys, always all of them (their order is not part of the contract, see section 3):

| Key | Type | Meaning |
|---|---|---|
| `ok` | bool | True for a success. |
| `payload` | string or null | The line the text form prints on stdout. |
| `reason` | string or null | Why it failed. Null on success, and for a bare failure. |
| `warning` | string or null | A warning that came with a success. |
| `json` | object or null | The command's JSON payload: the status object (section 3) for every successful session command in section 1. Null on failure. |

**Exit codes:**

| Code | When |
|---|---|
| 0 | Success. Also `session watch` ending because the app went away. |
| 1 | Any failure: a refusal, a bad argument, `app not running`, a timeout. |

Failures the CLI itself reports, before or without the app:
- `app not running`: nothing listens on the socket, and the CLI couldn't or wasn't allowed to start the app.
- `timed out; the session change may still complete, check session status`: the app didn't answer in time. A start or end it already began carries on.
- Argument errors: `invalid argument '<arg>'`, `--json takes no value`, `--timeout needs a positive number of seconds, at most 86400`.

Reasons are written for people and logs. Within version 1 their wording can change, so a program decides by `ok`, the exit code and the status object, not by matching reason text.

## 3. The status object

Every successful `--json` answer to `session start`, `session end`, `session resize` and `session status`, and every `--json` line of `session watch`, carries the status object in `json`.

**With no session** it has exactly these two keys:

```json
{"state":"idle","apiVersion":1}
```

**Key order is not part of the contract**, in the status object, the envelope, the watch wrapper or any other JSON this document shows. The CLI happens to print the status object's keys sorted (`{"apiVersion":1,"state":"idle"}`), and that can change within version 1. A caller parses the JSON and never compares it as text.

**With a session** every key below is present. A value that isn't known yet is null.

| Key | Type | Meaning |
|---|---|---|
| `apiVersion` | number | `1`. |
| `state` | string | `starting`, `active`, `degraded` or `ending` (below). |
| `client` | string | The client name the session was started with. |
| `displayID` | number or null | The virtual screen's `CGDirectDisplayID`. Null while the screen doesn't exist or isn't online: during a start, while it is being made again, and during an end. |
| `displayUUID` | string or null | The virtual screen's UUID, uppercase with dashes, the same string `CGDisplayCreateUUIDFromDisplayID` gives. Null whenever `displayID` is. |
| `looksLike` | `{"w","h"}` | The size in points ("looks like"). |
| `pixels` | `{"w","h"}` | The size in pixels: twice `looksLike` with HiDPI, the same without. |
| `hiDPI` | bool | Whether the screen is HiDPI. |
| `hz` | number | The refresh rate. |
| `ownerPIDs` | array of numbers | The owner processes (section 7), in the order they were added. Empty with no owner. |
| `physicalOff` | array of numbers | Display IDs of the monitors this session turned off that are still off, smallest first. |

Every number is a whole number, written without a decimal point or exponent.

The states:
- `starting`: a start is running. The monitors may still be on.
- `active`: the screen is up and main, the monitors are off, and the app puts things back if something changes them.
- `degraded`: the app stopped putting things back after too many changes in a short time (5 in 60 seconds). The session still works and ends normally.
- `ending`: an end is running, or the last end failed. After a failed end, `porchlight rescue` is the way out.

**Which ID to capture.** `displayID` changes every time the screen is made again: when the app relaunches during a session and resumes it, and when a resize goes past the largest size the screen was made with. `displayUUID` stays the same for a given client name, across resizes, relaunches and later sessions. So capture by `displayID`, always from the latest status, and use `displayUUID` to recognize the screen.

**The text form** (`payload`, and stdout without `--json`) is unchanged from Phase 1, because the Parsec scripts read it:

```
state=active client=parsec displayID=9 UUID=63C872E8-4E48-4D23-9889-F8EE8F82BEEE lookslike=1728x1080 pixels=3456x2160 hz=60 off=2,4
```

With no session it is `state=idle`. A field that isn't known yet is left out, and `off=` is always there.

## 4. `session start`

```
porchlight session start [-client=<name>] [-lookslike=<W>x<H>] [-hidpi=on|off] [-hz=<n>] [-preset=<name>]
                         [-ownerpid=<pid>]... [-keepon=<UUID>]... [--json]
```

- Defaults: `-client=default -lookslike=1728x1080 -hidpi=on -hz=60`.
- Limits: width 640 to 3840, height 360 to 2400, hz 24 to 240.
- `-preset` names a saved size (`porchlight session presets` lists them, case is ignored). It can't be combined with `-lookslike`, `-hidpi` or `-hz`.
- A client name is letters, digits, dot, dash and underscore.
- Parameter names ignore case, and `-name` and `--name` mean the same.
- It creates the virtual screen `Porch Light (<client>)`, makes it the main display, turns off every monitor not named by `-keepon`, and answers once all that is done, with state `active`.
- From the client that holds the session, a start adds its owners, keeps the current size (so a second guest doesn't undo a size someone picked) and answers with the status.
- From any other client it fails with `session held by <client>`.
- It needs the guardian running.
- A start that fails after it changed something rolls back first: the monitors come back and the screen goes.

Failure reasons a caller may see, among others: `session held by <client>`, `owner process <pid> is not running`, `guardian not running`, `lookslike width must be 640 to 3840` (and the same for height and hz), `unknown parameter: <name>`, `invalid <name>: <value>`, `unknown preset: <name>`, `the last session did not end cleanly; run porchlight rescue`, `app is quitting`, `cannot write state`.

## 5. `session end`

```
porchlight session end [-client=<name>] [-force] [-reason=<text>] [--json]
```

- No `-client` means `default`, the same as for a start.
- With no session it does nothing and succeeds, so a disconnect handler can always call it.
- From a client that doesn't hold the session it fails with `session held by <client>`, unless `-force`.
- It brings the monitors back to their recorded modes and positions, makes the recorded main display main again, removes the screen, and answers once that's done.
- The text form prints nothing. `json` is the status after the end, normally `{"state":"idle","apiVersion":1}`.
- A success can carry a warning: `not restored: <name>` for a monitor that was unplugged, `not restored at recorded mode: <name>` for one that came back at another mode.
- If the end fails (for example `a display did not come back correctly`), the state stays `ending`, and `porchlight rescue` brings everything back.
- `-reason` is only written to the session log.

## 6. `session resize` and `session status`

```
porchlight session resize -lookslike=<W>x<H> [-hidpi=on|off] [-hz=<n>] [--json]
porchlight session resize -preset=<name> [--json]
porchlight session status [--json]
```

- `resize` changes the running session's screen and never touches the monitors. What it leaves out stays as the session has it. `json` is the status after the resize. With no session it fails with `no session`.
- `status` takes no parameters and changes nothing. `json` is the status object.

## 7. Owners

- `-ownerpid=<pid>` ties the session to a process. It can be given more than once, and a repeated start from the holding client adds more owners. An owner can't be removed except by ending the session.
- Each owner is recorded as its PID and its start time, so a PID that the system reuses for another process never counts as the owner.
- A PID that isn't running at the start is refused (`owner process <pid> is not running`).
- **The rule: when any one owner exits, the session ends.** The guardian checks every 250 ms. It asks the app to end the session (logged with the reason `owner-died`). If the session hasn't ended 8 seconds later, and the app isn't visibly still ending it, the guardian brings the monitors back itself. If the app is dead too, the guardian brings them back at once.
- A session with no owner lasts until an end, a rescue, or the app quitting.
- If the app dies while every owner is alive, the guardian relaunches it (at most twice without a healthy stretch between). The relaunched app resumes the session on a new screen, so with a new `displayID`, and posts `sessionChanged`. Past that budget the guardian brings the monitors back.
- An orderly quit of the app ends the session first.

## 8. Following changes

### 8.1 The distributed notification

`com.alexluncan.PorchLight.sessionChanged` is posted to `DistributedNotificationCenter.default()` with no object and no `userInfo`, delivered immediately (`deliverImmediately: true`). It is posted after each of these:
- a session became `active`: a start finished, or the app resumed a session at launch;
- a resize finished;
- the screen was made again (a new `displayID`);
- the session became `degraded`;
- a session ended (now idle), or an end failed (still `ending`);
- a rescue finished.

It is not posted for a repeated start that only adds owners, or for a start refused before anything changed.

**It carries nothing.** On receiving it, a caller asks for the status (`session status --json`, or `status()` in the library). Treat it as a nudge: the status is always the truth.

The app also posts `com.alexluncan.PorchLight.launched` once it is ready for commands, and `com.alexluncan.PorchLight.terminated` when it quits, after ending any session. A dry run (`AD_DRY_RUN=1`) posts none of these.

### 8.2 `session watch`

```
porchlight session watch [--json] [--no-launch] [--timeout=<seconds>]
```

- It prints the current status first, the same line `session status` prints, then a new line each time the session changes, at the same moments the notification is posted, in order. A change that leaves the status exactly as the last line showed prints nothing.
- With `--json` every line is the same envelope `session status --json` prints, with the status object in `json`.
- Lines are written as they happen, so a pipe gets each one at once.
- It runs until it's killed, or until the app goes away, and then it exits 0. A quit ends any session first, so the last line before the exit is normally `state=idle`. After a crash, the last line can still show the session.
- While the app is busy (starting or quitting), or a request times out or its connection drops, watch asks again every 200 ms. But as soon as nothing listens on the socket, it exits 0, and it doesn't wait for a new app. A crash and the guardian's relaunch, or a restart from the status menu, leave a gap like that, so watch normally exits there too. Only if the new app is already listening when watch asks again does it carry on with the new app, printing the new app's status if it differs from the last line.
- So a caller that keeps following across a relaunch watches for the distributed notification `com.alexluncan.PorchLight.launched` (section 8.1) and starts a new `session watch` when it arrives. The new watch's first line is the new app's status, with the new `displayID`.
- Like `session status`, it starts the app if it isn't running, unless `--no-launch`. `--timeout` limits only the wait for the first answer.
- It exits 1 with `Failed. <reason>` if the first answer fails: `app not running` with `--no-launch`, or `unknown session operation: watch; ...` from an app older than this API.
- It takes no parameters (`-<name>`); one fails with `unknown parameter: <name>`.

## 9. The control socket

The CLI and `PorchLightClient` talk to the app over its control socket, a Unix socket at `~/Library/Application Support/PorchLight/ctl.sock` (`AD_SOCKET_PATH` moves it, for tests). Only processes of the same user can connect. This section is part of version 1 because `PorchLightClient` is built into other apps and talks to whatever Porch Light is installed. Anyone else uses the CLI or the library.

Each message is one JSON object and a newline. A request:

```json
{"v":1,"id":"<unique>","operations":["session","start"],"parameters":[["client","ipad"],["lookslike","1180x820"],["ownerpid","4242"]],"client":"<process name>"}
```

`parameters` is a list of `[name, value]` pairs, the value null for a bare flag such as `-force`. The answer has the same `id`, and leaves out keys with no value:

```json
{"v":1,"id":"<unique>","ok":true,"payload":"state=active ...","json":{"apiVersion":1,"state":"active","...":"..."}}
```

An answer `{"ok":false,"busy":"starting"}` means the app isn't ready yet (or is quitting). The request did not run, so it is safe to send again.

**`session watch` on the socket is a long poll**, so it needs no second socket:
- `session watch` with no parameters answers at once.
- `session watch -instance=<i> -after=<n> -wait=<s>` answers as soon as there is a change numbered after `<n>`, or after `<s>` seconds (0 to 60) with none.
- The answer's `payload` is the status line, and its `json` is `{"apiVersion":1,"instance":"<i>","change":<n>,"status":<status object>}`.
- `instance` names one run of the app. Change numbers count from 0 at each launch, so an answer with a different `instance` means: start over from this status. An answer whose `instance` differs from the one asked for comes at once.
- When a change after `<n>` is waiting, the answer carries the status as it was at that change, and the next one with the following change, so a client that always asks with the last number it got sees every change in order. The app keeps the last 32.
- An answer with the same `instance` and `change` that was asked for means nothing changed: ask again.

The CLI and the library print or return only the status object, never this wrapper.

## 10. Versioning

- This is version 1, and every status object says so in `apiVersion`.
- Within version 1, Porch Light may add keys to the status object or the watch wrapper, add session operations and parameters, and add or reword failure reasons. Callers ignore keys they don't know.
- Anything else needs version 2: removing or renaming a key, changing a key's type or meaning, a new `state` value, a change to the owner rule, the notification's name, or the socket messages in section 9.
- `PorchLightClient` checks `apiVersion` on every answer and refuses any other version with `PorchLightClientError.unsupportedReply`.

## 11. `PorchLightClient`

A Swift library product in this package (`PorchLightKit`), target `PorchLightClient`, macOS 26 or later. It depends only on `ADIPC`, `ADModel` and `ADFoundation` (the socket, the request types, and the socket's path), never on the engine.

```swift
public struct PorchLightClient: Sendable {
    public static let apiVersion = 1
    public init(socketPath: String? = nil, launchesApp: Bool = true)
    public func start(client: String, looksLike: PorchLightSize, hiDPI: Bool = true, hz: Int = 60,
                      ownerPIDs: [Int32] = [ProcessInfo.processInfo.processIdentifier])
        async throws(PorchLightClientError) -> PorchLightStatus
    public func end(client: String) async throws(PorchLightClientError) -> PorchLightStatus
    public func status() async throws(PorchLightClientError) -> PorchLightStatus
    public func changes() -> AsyncStream<PorchLightStatus>
}
```

- `PorchLightStatus` mirrors the status object: `apiVersion`, `state`, `client`, `displayID` (`CGDirectDisplayID?`), `displayUUID`, `looksLike` and `pixels` (`PorchLightSize?`, width and height), `hiDPI`, `hz`, `ownerPIDs`, `physicalOff`. It has a public initializer, for a caller's own fakes.
- `start` and `end` start the app if it isn't running, the same way the CLI does, unless `launchesApp` is false, a `socketPath` is given, or the process runs under a test override (`AD_SOCKET_PATH`, `AD_STATE_DIR` or `AD_DRY_RUN`). `status` and `changes` never start it.
- `start` ties the session to the calling process by default.
- Timeouts: 60 seconds for `start` and `end`, including a launch, and 15 for `status`.
- `changes()` yields the current status, then the status after each change, the same as `session watch`. The stream finishes when the app goes away, at once if it isn't running, and in the gap of a crash and relaunch (on `launched`, start a new `changes()`). When the reader stops, the watch stops once the long poll in flight comes back (15 seconds at most while the app answers).
- `changes()` also finishes on an answer it can't use: a failure, or a status it can't read, such as one with `apiVersion` 2. The stream carries no error. So when it finishes, call `status()`: it returns the status now, or throws the typed reason (`unsupportedReply` for another API version, `appNotRunning` once the app is gone). Never keep capturing the `displayID` of the last status the stream gave until a new `status()` or stream confirms it.
- Errors are `PorchLightClientError`: `appNotRunning`, `timedOut` (the call may still complete; ask for the status), `failed(String)` (Porch Light refused, with its reason), `unsupportedReply(String)`.
