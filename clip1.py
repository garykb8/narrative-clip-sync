#!/usr/bin/env python3
"""USB client for the Narrative Clip 1 (Memoto).

Protocol reverse-engineered from Narrative Uploader 2.5.3 (CameraV2 / ClipOneStrategy):

  * Device: VID 0xF0F0, PID 0x1337, vendor-specific class.
  * Commands are vendor control transfers to the device (bmRequestType 0x40 OUT / 0xC0 IN,
    wValue 0). Path arguments are NUL-terminated strings in the data stage.
  * Responses to file commands arrive on the bulk IN endpoint.
  * File entries are 132-byte records: u32 size @0, u32 d_type @4 (only the low byte is
    meaningful: 4 = directory, 8 = regular file), char name[124] @8.

Write commands are limited to setting the clock (set-property 0x05 on the time property) and
deleting event files that are already safely on the Mac (0x03); both are answered with "ACK"
on the bulk pipe. Firmware update (0x10/0x11) is never sent.
"""
import argparse
import os
import re
import struct
import sys
import time

import usb.core
import usb.util

VID, PID = 0xF0F0, 0x1337

REQ_READ_FILE = 0x02
REQ_DELETE_FILE = 0x03
REQ_GET_PROPERTY = 0x04
REQ_SET_PROPERTY = 0x05
REQ_LIST_DIR = 0x09

PROP_DEVICE_ID = 1
PROP_FIRMWARE_VERSION = 2
PROP_TIME = 4

ENTRY_SIZE = 0x84
DT_DIR, DT_REG = 4, 8
END_MARKER = struct.pack('<Q', 0x00FFFFAA55FFFF00)
STORAGE_ROOT = '/mnt/storage'


class Clip:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            sys.exit('Narrative Clip not found (VID 0xF0F0 / PID 0x1337). Is it plugged in?')
        try:
            self.dev.set_configuration()
        except usb.core.USBError:
            pass  # already configured
        intf = self.dev.get_active_configuration()[(0, 0)]
        usb.util.claim_interface(self.dev, intf)
        self.ep_in = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
            and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
        if self.ep_in is None:
            sys.exit('Bulk IN endpoint not found')
        # A transfer left half-read by an earlier session can wedge the firmware so that even
        # control requests time out; a USB port reset recovers it without touching storage.
        try:
            self.get_property(PROP_DEVICE_ID)
        except usb.core.USBTimeoutError:
            self.dev.reset()
            self.__init__()

    def _ctrl_out(self, req, data=b'', index=0):
        self.dev.ctrl_transfer(0x40, req, 0, index, data, timeout=5000)

    def _ctrl_path(self, req, path):
        self._drain()
        self._ctrl_out(req, path.encode() + b'\0')

    def _bulk_read(self, size, timeout):
        return bytes(self.ep_in.read(size, timeout=timeout))

    def _drain(self):
        # Discard anything left in the bulk pipe (e.g. a trailing zero-length packet from a
        # previous transfer) so the next response isn't read out of step.
        while True:
            try:
                self._bulk_read(0x10000, timeout=100)
            except usb.core.USBTimeoutError:
                return

    def get_property(self, prop, length=0x80):
        return bytes(self.dev.ctrl_transfer(0xC0, REQ_GET_PROPERTY, 0, prop, length, timeout=5000))

    def info(self):
        cstr = lambda b: b.split(b'\0', 1)[0].decode(errors='replace')
        t = struct.unpack_from('<I', self.get_property(PROP_TIME))[0]
        return {
            'device_identifier': cstr(self.get_property(PROP_DEVICE_ID)),
            'firmware_version': cstr(self.get_property(PROP_FIRMWARE_VERSION)),
            'camera_time': time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(t)),
            'time_diff_s': int(time.time()) - t,
        }

    def set_time(self, t=None):
        """Set the camera clock (what the official app does on every connect)."""
        self._drain()
        self._ctrl_out(REQ_SET_PROPERTY, struct.pack('<I', int(time.time() if t is None else t)), index=PROP_TIME)
        self._wait_for_ack('set_time')

    def delete_file(self, path):
        self._ctrl_path(REQ_DELETE_FILE, path)
        self._wait_for_ack(f'delete {path}')

    def _wait_for_ack(self, what):
        ack = self._bulk_read(4, timeout=20000)
        if ack.split(b'\0', 1)[0] != b'ACK':
            raise IOError(f'Camera did not ACK {what}: {ack!r}')

    def list_dir(self, path):
        self._ctrl_path(REQ_LIST_DIR, path)
        buf = b''
        while True:
            buf += self._bulk_read(0x10000, timeout=60000)
            n = len(buf) // ENTRY_SIZE
            if n and buf[(n - 1) * ENTRY_SIZE + 8:(n - 1) * ENTRY_SIZE + 16] == END_MARKER:
                break
        entries = []
        for i in range(n - 1):
            rec = buf[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE]
            size, d_type = struct.unpack_from('<II', rec)
            name = rec[8:].split(b'\0', 1)[0].decode(errors='replace')
            entries.append({'name': name, 'size': size, 'is_dir': d_type & 0xFF == DT_DIR})
        return entries

    def read_file(self, path):
        self._ctrl_path(REQ_READ_FILE, path)
        first = b''
        while len(first) < ENTRY_SIZE:
            first += self._bulk_read(0x10000, timeout=10000)
        size = struct.unpack_from('<I', first)[0]
        name = first[8:ENTRY_SIZE].split(b'\0', 1)[0].decode(errors='replace')
        if size == 0 or name != path:
            raise IOError(f'Invalid file: path={path!r}, f_name={name!r}, size={size}')
        data = bytearray(first[ENTRY_SIZE:])
        # Always ask for whole 64 KiB transfers so a terminating zero-length packet is consumed.
        while len(data) < size:
            data += self._bulk_read(0x10000, timeout=60000)
        if len(data) != size:
            raise IOError(f'Size mismatch for {path}: expected {size}, got {len(data)}')
        return bytes(data)


def entry_path(parent, name):
    # Entries may come back as full paths or bare names; normalise to a full path.
    return name if name.startswith('/') else f"{parent.rstrip('/')}/{name}"


def cmd_info(clip, args):
    for k, v in clip.info().items():
        print(f'{k:18} {v}')


def cmd_settime(clip, args):
    before = clip.info()
    clip.set_time()
    after = clip.info()
    print(f"camera_time {before['camera_time']} -> {after['camera_time']} (was off by {before['time_diff_s']} s)")


def cmd_ls(clip, args):
    for e in clip.list_dir(args.path):
        print(f"{'d' if e['is_dir'] else '-'} {e['size']:>10}  {e['name']}")


def cmd_get(clip, args):
    data = clip.read_file(args.path)
    out = args.out or os.path.basename(args.path)
    with open(out, 'wb') as f:
        f.write(data)
    print(f'{len(data)} bytes -> {out}')


def cmd_tree(clip, args):
    def walk(path, depth):
        for e in clip.list_dir(path):
            print(f"{'  ' * depth}{e['name']}{'/' if e['is_dir'] else ''}  ({e['size']})")
            if depth + 1 < args.depth and e['is_dir']:
                walk(entry_path(path, e['name']), depth + 1)
    walk(args.path, 0)


EVENT_RE = re.compile(r'^(event_(\d{2})(\d{2})(\d{2})_\d{6}_[0-9a-f]{32})\.')
DEFAULT_DEST = os.path.expanduser('~/Pictures/Narrative Clip/Clip Sync')


def read_local(path):
    try:
        with open(path, 'rb') as f:
            return f.read()
    except FileNotFoundError:
        return None


def cmd_pull(clip, args):
    """Copy events to DEST/clip_<serial>/YYYY/MM/DD/; with --delete, remove them from the camera.

    An event (all files sharing one event_* prefix) is only deleted once every one of its files
    has been read back from the Mac's disk and matches the camera byte for byte. .boot events
    (10-byte boot records) are never copied; with --delete they are simply removed.
    """
    serial = clip.info()['device_identifier']
    if not args.no_set_time:
        cmd_settime(clip, args)
    root = os.path.join(args.dest, f'clip_{serial[-8:]}')

    events = {}  # (dir, event) -> [(camera path, size, local path or None)]
    for d in clip.list_dir(STORAGE_ROOT):
        if not d['is_dir']:
            continue
        dpath = entry_path(STORAGE_ROOT, d['name'])
        for e in clip.list_dir(dpath):
            m = EVENT_RE.match(e['name'])
            if e['is_dir'] or not m:
                continue
            event, yy, mm, dd = m.groups()
            out = None if e['name'].endswith('.boot') else os.path.join(root, f'20{yy}', mm, dd, e['name'])
            events.setdefault((dpath, event), []).append((entry_path(dpath, e['name']), e['size'], out))

    copied = deleted = 0
    for (dpath, event), files in sorted(events.items(), key=lambda kv: kv[0][1]):
        verified = True
        for src, size, out in files:
            if out is None:
                continue
            local = read_local(out)
            if local is not None and len(local) == size and not args.delete:
                continue  # already synced; size check is enough when nothing will be deleted
            data = clip.read_file(src)
            if local != data:
                os.makedirs(os.path.dirname(out), exist_ok=True)
                tmp = out + '.part'
                with open(tmp, 'wb') as f:
                    f.write(data)
                os.replace(tmp, out)
                copied += 1
                print(f'copied   {size:>8}  {os.path.relpath(out, root)}')
            if read_local(out) != data:
                print(f'MISMATCH {os.path.relpath(out, root)} -- keeping event on camera')
                verified = False
        if args.delete and verified:
            for src, _, _ in files:
                clip.delete_file(src)
                deleted += 1
            print(f'deleted  {event} ({len(files)} file(s))')
    print(f'done: {copied} file(s) copied, {deleted} file(s) deleted from camera -> {root}')


def main():
    p = argparse.ArgumentParser(description='Narrative Clip 1 USB client')
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('info')
    s = sub.add_parser('ls'); s.add_argument('path', nargs='?', default=STORAGE_ROOT)
    s = sub.add_parser('tree'); s.add_argument('path', nargs='?', default=STORAGE_ROOT); s.add_argument('--depth', type=int, default=2)
    s = sub.add_parser('get'); s.add_argument('path'); s.add_argument('-o', '--out')
    s = sub.add_parser('pull', help='copy photos to the Mac (and optionally clear them from the camera)')
    s.add_argument('--dest', default=DEFAULT_DEST)
    s.add_argument('--delete', action='store_true', help='remove events from the camera once verified on the Mac')
    s.add_argument('--no-set-time', action='store_true', help="don't sync the camera clock first")
    sub.add_parser('settime', help="set the camera clock to the Mac's time")
    args = p.parse_args()
    clip = Clip()
    {'info': cmd_info, 'ls': cmd_ls, 'get': cmd_get, 'tree': cmd_tree, 'pull': cmd_pull, 'settime': cmd_settime}[args.cmd](clip, args)


if __name__ == '__main__':
    main()
