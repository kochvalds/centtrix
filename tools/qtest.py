#!/usr/bin/env python3
"""Centtrix QEMU test kit: boot, login, mouse, keyboard, screenshots."""
import subprocess, socket, time, os, re, zlib, struct, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = os.path.join(ROOT, 'centtrix.img')
TMP = os.environ.get('CENTTRIX_TMP', '/tmp/opencode')
MON = os.path.join(TMP, 'mon.sock')
QMPS = os.path.join(TMP, 'qmp.sock')
SHOTS = TMP

CH = {c: c for c in 'abcdefghijklmnopqrstuvwxyz0123456789'}
CH.update({' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus', '=': 'equal',
           ',': 'comma', ';': 'semicolon', '>': 'shift-dot', '<': 'shift-comma',
           ':': 'shift-semicolon', '"': 'shift-apostrophe', '?': 'shift-slash',
           '!': 'shift-1', '@': 'shift-2', '#': 'shift-3', '$': 'shift-4',
           '%': 'shift-5', '^': 'shift-6', '&': 'shift-7', '*': 'shift-8',
           '(': 'shift-9', ')': 'shift-0', '_': 'shift-minus', '+': 'shift-equal',
           '|': 'shift-backslash', '`': 'grave_accent', '~': 'shift-grave_accent',
           '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
           "'": 'apostrophe', '{': 'shift-bracket_left', '}': 'shift-bracket_right'})


class HMP:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(5)
        self.s.connect(MON)
        self.drain()

    def drain(self):
        self.s.settimeout(0.2)
        try:
            while True:
                if not self.s.recv(65536):
                    break
        except Exception:
            pass
        self.s.settimeout(5)

    def cmd(self, c):
        self.s.sendall((c + '\n').encode())
        time.sleep(0.04)
        self.drain()

    def raw(self, c):
        self.drain()
        self.s.sendall((c + '\n').encode())
        time.sleep(0.4)
        self.s.settimeout(1.0)
        buf = b''
        try:
            while True:
                d = self.s.recv(65536)
                if not d:
                    break
                buf += d
                if b'(qemu)' in buf:
                    break
        except Exception:
            pass
        self.s.settimeout(5)
        return buf.decode('utf-8', 'replace')


class QMPC:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(10)
        self.s.connect(QMPS)
        buf = b''
        while b'\n' not in buf:
            buf += self.s.recv(4096)
        self.send('qmp_capabilities', {})

    def send(self, name, args):
        self.s.sendall((json.dumps({'execute': name, 'arguments': args}) + '\n').encode())
        buf = b''
        while b'\n' not in buf:
            d = self.s.recv(65536)
            if not d:
                raise EOFError
            buf += d
        return buf


class Box:
    def __init__(self, boot_wait=20):
        self.proc = None
        self.h = None
        self.q = None
        self.boot_wait = boot_wait

    # ---- lifecycle ----
    def pkill(self):
        os.system('pkill qemu-system-x86')
        time.sleep(1)

    def start(self, wait=None):
        self.pkill()
        for f in (MON, QMPS):
            try:
                os.unlink(f)
            except FileNotFoundError:
                pass
        self.proc = subprocess.Popen(
            ['qemu-system-x86_64', '-drive', 'format=raw,file=' + IMG,
             '-m', '512', '-nic', 'user,model=e1000', '-rtc', 'base=localtime',
             '-display', 'none', '-monitor', 'unix:' + MON + ',server,nowait',
             '-qmp', 'unix:' + QMPS + ',server,nowait', '-no-reboot']
            + os.environ.get('QEMU_EXTRA', '').split(),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(300):
            if os.path.exists(MON) and os.path.exists(QMPS):
                break
            time.sleep(0.1)
        time.sleep(0.3)
        time.sleep(self.boot_wait if wait is None else wait)
        self.h = HMP()
        self.q = QMPC()
        return self

    def stop(self):
        if self.proc:
            self.proc.terminate()
        time.sleep(2)

    # ---- input ----
    def key(self, k, d=0.12):
        self.h.cmd('sendkey ' + k)
        time.sleep(d)

    def ty(self, s, d=0.12):
        for ch in s:
            if ch == '\n':
                self.key('ret', 0.35)
            else:
                self.key(CH[ch], d)

    def chord(self, *keys, d=0.35):
        self.h.cmd('sendkey ' + '-'.join(keys))
        time.sleep(d)

    def warm(self):
        self.key('x', 0.3)
        self.key('backspace', 0.25)

    def rel(self, dx, dy, d=0.03):
        self.q.send('input-send-event', {'events': [
            {'type': 'rel', 'data': {'axis': 'x', 'value': dx}},
            {'type': 'rel', 'data': {'axis': 'y', 'value': dy}}]})
        time.sleep(d)

    def move(self, x, y):
        for _ in range(30):
            self.rel(-48, 0)
        for _ in range(24):
            self.rel(0, -48)
        dx = x
        while dx > 0:
            d = min(48, dx)
            self.rel(d, 0)
            dx -= d
        dy = y
        while dy > 0:
            d = min(48, dy)
            self.rel(0, d)
            dy -= d
        time.sleep(0.2)

    def click(self, x, y, pause=0.4):
        self.move(x, y)
        self.q.send('input-send-event', {'events': [
            {'type': 'btn', 'data': {'down': True, 'button': 'left'}}]})
        time.sleep(0.14)
        self.q.send('input-send-event', {'events': [
            {'type': 'btn', 'data': {'down': False, 'button': 'left'}}]})
        time.sleep(pause)

    def shot(self, name):
        p = os.path.join(SHOTS, name)
        self.h.cmd('screendump ' + p + '.ppm')
        time.sleep(0.5)
        d = open(p + '.ppm', 'rb').read()
        mt = re.match(rb'P6\s+(\d+)\s+(\d+)\s', d or b'')
        w, hh = int(mt.group(1)), int(mt.group(2))
        px = d[mt.end(): mt.end() + w * hh * 3]

        def chunk(t, b):
            return (struct.pack('>I', len(b)) + t + b +
                    struct.pack('>I', zlib.crc32(t + b) & 0xffffffff))
        raw = b''.join(b'\x00' + px[y * w * 3:(y + 1) * w * 3] for y in range(hh))
        open(p + '.png', 'wb').write(
            b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, hh, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
        print('shot', name, flush=True)

    # ---- composite ----
    def unlock(self):
        """boot ends on a 'Press any key to unlock' clock screen"""
        self.key('space', 0.6)
        time.sleep(1.4)

    def login(self, pw='1234'):
        self.unlock()
        self.ty(pw)
        self.ty('\n')
        time.sleep(2.5)
