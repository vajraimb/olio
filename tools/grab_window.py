"""Launch olio in a fresh console window and grab a picture of that window."""

import ctypes, ctypes.wintypes as wt, subprocess, sys, time
from PIL import ImageGrab

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass


class RECT(ctypes.Structure):
    _fields_ = [("Left", ctypes.c_long), ("Top", ctypes.c_long),
                ("Right", ctypes.c_long), ("Bottom", ctypes.c_long)]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def console_windows():
    found = []
    hwnds = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, lparam):
        cls = ctypes.create_unicode_buffer(256)
        u32.GetClassNameW(hwnd, cls, 256)
        if cls.value == "ConsoleWindowClass" and u32.IsWindowVisible(hwnd):
            hwnds.append(hwnd)
        return True

    u32.EnumWindows(cb, 0)
    return hwnds


def title_of(hwnd):
    b = ctypes.create_unicode_buffer(512)
    u32.GetWindowTextW(hwnd, b, 512)
    return b.value


def rect_of(hwnd):
    r = RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    tl = POINT(r.Left, r.Top)
    u32.ClientToScreen(hwnd, ctypes.byref(tl))
    return (tl.x, tl.y, tl.x + (r.Right - r.Left), tl.y + (r.Bottom - r.Top))


def main():
    exe, args, out = sys.argv[1], sys.argv[2:-1], sys.argv[-1]
    before = set(console_windows())

    CREATE_NEW_CONSOLE = 0x00000010
    p = subprocess.Popen([exe] + args, creationflags=CREATE_NEW_CONSOLE,
                         close_fds=True)
    time.sleep(2.5)

    new = [h for h in console_windows() if h not in before]
    print("olio pid:", p.pid, "alive:", p.poll() is None)
    print("new console windows:", len(new))
    for h in new:
        print("  title:", repr(title_of(h)), "rect:", rect_of(h))
    if not new:
        print("ERROR: no console window found")
        p.terminate()
        return 1

    hwnd = new[0]
    u32.SetForegroundWindow(hwnd)
    time.sleep(0.8)
    box = rect_of(hwnd)
    ImageGrab.grab(bbox=box, all_screens=True).save(out)
    print("saved:", out)

    p.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
