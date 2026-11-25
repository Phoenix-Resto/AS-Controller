"""Local-network keyboard receiver. Run on Windows with: python host.py."""
import asyncio
import ctypes
from ctypes import wintypes
import json
import platform
import secrets
import socket
import sys
from dataclasses import dataclass, field

import websockets

PORT = 8765

# Explicit, predictable keyboard vocabulary for version 1.
KEYS = {**{chr(n): n for n in range(65, 91)},
        **{str(n): 48 + n for n in range(10)},
        'UP': 0x26, 'DOWN': 0x28, 'LEFT': 0x25, 'RIGHT': 0x27,
        'SPACE': 0x20, 'ENTER': 0x0D, 'ESC': 0x1B, 'TAB': 0x09,
        'SHIFT': 0x10, 'CTRL': 0x11, 'ALT': 0x12, 'BACKSPACE': 0x08,
        **{f'F{n}': 0x6F + n for n in range(1, 13)}}
EXTENDED = {'UP', 'DOWN', 'LEFT', 'RIGHT', 'CTRL', 'ALT'}

if platform.system() == 'Windows':
    ULONG_PTR = ctypes.c_size_t

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [('wVk', wintypes.WORD), ('wScan', wintypes.WORD),
                    ('dwFlags', wintypes.DWORD), ('time', wintypes.DWORD),
                    ('dwExtraInfo', ULONG_PTR)]

    class INPUT_UNION(ctypes.Union):
        _fields_ = [('ki', KEYBDINPUT)]

    class INPUT(ctypes.Structure):
        _anonymous_ = ('u',)
        _fields_ = [('type', wintypes.DWORD), ('u', INPUT_UNION)]

    SendInput = ctypes.windll.user32.SendInput
    SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
    SendInput.restype = wintypes.UINT
    MapVirtualKeyW = ctypes.windll.user32.MapVirtualKeyW
    MapVirtualKeyW.argtypes = (wintypes.UINT, wintypes.UINT)
    MapVirtualKeyW.restype = wintypes.UINT


def inject(key: str, down: bool) -> None:
    if platform.system() != 'Windows':
        raise RuntimeError('Keyboard injection requires Windows')
    scan = MapVirtualKeyW(KEYS[key], 0)
    if not scan:
        raise RuntimeError(f'No scancode for {key}')
    flags = 0x0008 | (0x0001 if key in EXTENDED else 0) | (0 if down else 0x0002)
    event = INPUT(type=1, u=INPUT_UNION(ki=KEYBDINPUT(0, scan, flags, 0, 0)))
    if SendInput(1, ctypes.byref(event), ctypes.sizeof(INPUT)) != 1:
        raise ctypes.WinError()


@dataclass(eq=False)
class Client:
    ws: object
    name: str = 'Phone'
    mappings: dict[str, str] = field(default_factory=dict)
    pressed: set[str] = field(default_factory=set)
    authorized: bool = False


class ControllerServer:
    def __init__(self, pin: str):
        self.pin = pin
        self.clients: set[Client] = set()
        # Strict global uniqueness: key -> (client, control ID)
        self.owners: dict[str, tuple[Client, str]] = {}

    async def send(self, client, event, **kwargs):
        await client.ws.send(json.dumps({'type': event, **kwargs}))

    async def snapshot(self):
        assignments = [
            {'key': key, 'device': owner.name, 'control': control}
            for key, (owner, control) in sorted(self.owners.items())
        ]
        for client in list(self.clients):
            if client.authorized:
                try:
                    await self.send(client, 'state', assignments=assignments,
                                    mappings=client.mappings)
                except websockets.exceptions.ConnectionClosed:
                    pass

    def release(self, client: Client, control: str):
        if control not in client.pressed:
            return
        client.pressed.remove(control)
        key = client.mappings.get(control)
        if key:
            try:
                inject(key, False)
            except OSError as exc:
                print('Key release error:', exc)

    async def handler(self, ws):
        client = Client(ws)
        try:
            async for raw in ws:
                try:
                    payload = json.loads(raw)
                    if not isinstance(payload, dict):
                        continue
                    kind = payload.get('type')
                    if not client.authorized:
                        if kind != 'hello' or str(payload.get('pin', '')) != self.pin:
                            await self.send(client, 'error', message='Incorrect pairing PIN')
                            await ws.close(code=1008, reason='Unauthorized')
                            break
                        name = payload.get('name', 'Phone')
                        client.name = str(name)[:32] if name else 'Phone'
                        client.authorized = True
                        self.clients.add(client)
                        await self.send(client, 'welcome', keys=list(KEYS))
                        await self.snapshot()
                        print('Connected:', client.name)
                        continue
                    control = payload.get('control')
                    if kind == 'assign':
                        key = str(payload.get('key', '')).upper()
                        if not isinstance(control, str) or not (1 <= len(control) <= 64):
                            await self.send(client, 'error', message='Invalid control identifier')
                            continue
                        if key and key not in KEYS:
                            await self.send(client, 'error', message='Unsupported key')
                            continue
                        existing = self.owners.get(key) if key else None
                        if existing and existing != (client, control):
                            await self.send(client, 'error', message=f'{key} is already assigned to {existing[0].name} / {existing[1]}')
                            continue
                        self.release(client, control)
                        old = client.mappings.pop(control, None)
                        if old:
                            self.owners.pop(old, None)
                        if key:
                            client.mappings[control] = key
                            self.owners[key] = (client, control)
                        await self.snapshot()
                    elif kind in ('down', 'up'):
                        if not isinstance(control, str) or control not in client.mappings:
                            continue
                        if kind == 'down' and control not in client.pressed:
                            try:
                                inject(client.mappings[control], True)
                                client.pressed.add(control)
                            except OSError as exc:
                                await self.send(client, 'error', message=f'Input failed: {exc}')
                        elif kind == 'up':
                            self.release(client, control)
                    elif kind == 'release_all':
                        for held in list(client.pressed):
                            self.release(client, held)
                except (ValueError, TypeError) as exc:
                    await self.send(client, 'error', message=f'Bad message: {exc}')
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            for held in list(client.pressed):
                self.release(client, held)
            for key in list(client.mappings.values()):
                self.owners.pop(key, None)
            self.clients.discard(client)
            await self.snapshot()
            if client.authorized:
                print('Disconnected:', client.name)


def get_lan_ip():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(('192.0.2.1', 80))  # no packet is sent
        return sock.getsockname()[0]
    except OSError:
        return 'YOUR_PC_IP'
    finally:
        sock.close()


async def main():
    if platform.system() != 'Windows':
        sys.exit('The receiver must be run on Windows.')
    pin = f'{secrets.randbelow(1_000_000):06d}'
    server = ControllerServer(pin)
    print('AS Controller Windows Host | press Ctrl+C to stop')
    print(f'Address: ws://{get_lan_ip()}:{PORT}')
    print(f'Pairing PIN: {pin} (changes every restart)')
    print('Only connect phones you trust on your local Wi-Fi.')
    async with websockets.serve(server.handler, '0.0.0.0', PORT, max_size=8192):
        await asyncio.Future()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print('\nStopped')
