# Phase 1 — Keyboard controller prototype

**Baseline:** the `gamepad.zip` uploaded on 2026-11-25. Apply the patch ZIP at the root of the existing `gamepad` repository. No files are deleted.

## Windows host

1. From `gamepad/windows-host`, activate your existing `.venv`.
2. Run `python -m pip install -r requirements.txt` (the existing `websockets` 16.1 is compatible).
3. Run `python host.py`. Copy the LAN address and six-digit PIN shown in the terminal.
4. If Windows Firewall asks, allow Python on **Private networks only**. Do not port-forward this service onto the Internet.
5. Keep the console open while playing. This version's mappings exist only while the phone is connected.

## Android phone

1. In `gamepad/mobile`, run `flutter pub get`, then `flutter run -d <android-device-id>` (or `flutter run` if only one device is connected).
2. Connect phone and PC to the same non-isolated Wi-Fi network.
3. Enter the **PC IPv4 address**, not the TV or phone address, and the current host PIN.
4. Long-press any on-screen control, choose an **unused** key, then tap/hold the control to send key-down and release to send key-up.
5. Test in Notepad first, then in a game. Repeat with a second phone. Only a single control on all connected phones can own each PC key.

## Known scope and limits

- Fixed **12-button** prototype, no joystick or drag-to-edit canvas yet. The d-pad is four independent keys, and diagonal movement works by pressing two controls at once.
- Mapping is held by the Windows host and **strictly unique globally** across connected devices. Conflicts are rejected by the host, not just grayed out in the UI.
- All assignments are released when a phone disconnects. No persistence yet; profile saving and editing come later.
- The PC may block simulated input to elevated apps or games using raw input, exclusive controller input, or anti-cheat. Test first in Notepad.
- A six-digit PIN is provided for basic LAN pairing, **not strong security**. WebSocket data is unencrypted on local Wi-Fi; only use on a trusted private network.
- No external gamepad driver, virtual Xbox controller, emulation, or TV application is involved in this phase.

## Validation

From the repository root, with the host environment active:

```powershell
python -m unittest discover -s tests -v
cd mobile
flutter analyze
flutter test
```

Hold two different controls simultaneously, assign `W` to one and attempt another `W` on the same or second phone, verify rejection, then disconnect while holding a key and verify it releases.
