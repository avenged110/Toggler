# Toggler

A macOS 15 MenuBar applet that automatically toggles Wi-Fi and Bluetooth upon dock/undock and sleep/wake events.

- Automatically and independently toggle Wi-Fi and Bluetooth when connecting to, or disconnecting from, a Thunderbolt dock.
- Dock detection is handled through a series of heuristic probes which can be adjusted in Settings. The probes are skipped for recognized docks, keying off of these devices' UIDs.
- Automatically and independently disable Bluetooth and Wi-Fi when your Mac sleeps, and re-enable them on wake (if they were enabled before sleep).
- Bluetooth power is controlled through the private "IOBluetoothPreference" API.

Every day I disconnect my MacBook from its dock and use it with Wi-Fi enabled and Bluetooth disabled. Later, it gets docked in closed-clamshell mode where it's used with Wi-Fi disabled and Bluetooth enabled. I was quite surprised by how difficult it appeared to be to automate this. Plus, it seems that macOS keeps both radios enabled in a low-power state while a MacBook sleeps (like iOS devices do), with no way to opt-out of this behavior. So Toggler was born to solve these two issues in a simple and reliable manner.

## Installation and Usage

Toggler is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `Toggler.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/Toggler.app"
```

On first launch, Toggler will request Bluetooth permission via Apple's TCC system. This need only be granted if you plan on using the Bluetooth toggling functionality and can be adjusted at any time in System Settings > Privacy & Security > Bluetooth.

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only.
- "Bluetooth" permission via Apple's TCC system.
- Uses Apple's Hardened Runtime and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. If it affects macOS 15, I will try harder. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it largely feature-complete at this time.

Toggler is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

Toggler is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2025 avenged110. The full license text is in `COPYING`.

## Acknowledgments

Toggler's Bluetooth power control uses the same private Apple functions that blueutil (https://github.com/toy/blueutil, Copyright © 2011–2026 Ivan Kuchin, originally written by Frederik Seiffert, MIT License) documents. No blueutil code is included. Toggler is not affiliated with, endorsed by, or supported by these authors.
