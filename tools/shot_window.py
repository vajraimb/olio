"""Launch a command in its own console and capture that window with PrintWindow.

Unlike grabbing the screen this does not need the window to be in front, so it
neither steals focus nor photographs whatever else is on the desktop.

Usage: python shot_window.py <exe> [args...] --out <png> [--cwd <dir>]
"""

import ctypes, ctypes.wintypes as wt, subprocess, sys, os, time

u32 = ctypes.WinDLL("user32", use_last_error=True)
g32 = ctypes.WinDLL("gdi32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)

PW_RENDERFULLCONTENT = 0x00000002

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # physical pixels, else PrintWindow crops
except Exception:
    pass


class RECT(ctypes.Structure):
    _fields_ = [("Left", ctypes.c_long), ("Top", ctypes.c_long),
                ("Right", ctypes.c_long), ("Bottom", ctypes.c_long)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wt.DWORD), ("biWidth", ctypes.c_long),
                ("biHeight", ctypes.c_long), ("biPlanes", wt.WORD),
                ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD),
                ("biClrImportant", wt.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]


def console_windows():
    out = []

    @ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    def cb(h, l):
        cls = ctypes.create_unicode_buffer(256)
        u32.GetClassNameW(h, cls, 256)
        if cls.value == "ConsoleWindowClass" and u32.IsWindowVisible(h):
            out.append(h)
        return 1

    u32.EnumWindows(cb, 0)
    return out


def capture(hwnd, path):
    r = RECT()
    u32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.Right - r.Left, r.Bottom - r.Top
    if w <= 0 or h <= 0:
        return False, "empty rect"

    # The window rect includes the frame, so crop down to the client area.
    cr = RECT()
    u32.GetClientRect(hwnd, ctypes.byref(cr))
    org = wt.POINT(cr.Left, cr.Top)
    u32.ClientToScreen(hwnd, ctypes.byref(org))
    crop = (org.x - r.Left, org.y - r.Top,
            org.x - r.Left + (cr.Right - cr.Left),
            org.y - r.Top + (cr.Bottom - cr.Top))

    hdc_screen = u32.GetDC(None)
    hdc = g32.CreateCompatibleDC(hdc_screen)
    bmp = g32.CreateCompatibleBitmap(hdc_screen, w, h)
    g32.SelectObject(hdc, bmp)

    ok = u32.PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h  # top-down
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    bi.bmiHeader.biCompression = 0  # BI_RGB

    buf = ctypes.create_string_buffer(w * h * 4)
    got = g32.GetDIBits(hdc, bmp, 0, h, buf, ctypes.byref(bi), 0)

    from PIL import Image
    img = Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1)
    img = img.crop(crop)
    img.convert("RGB").save(path)

    g32.DeleteObject(bmp)
    g32.DeleteDC(hdc)
    u32.ReleaseDC(None, hdc_screen)
    return True, "printwindow=%s rows=%s client=%dx%d" % (bool(ok), got, cr.Right, cr.Bottom)


def main():
    argv = sys.argv[1:]
    out = None
    cwd = None
    if "--out" in argv:
        i = argv.index("--out")
        out = argv[i + 1]
        del argv[i:i + 2]
    if "--cwd" in argv:
        i = argv.index("--cwd")
        cwd = argv[i + 1]
        del argv[i:i + 2]

    exe, args = argv[0], argv[1:]
    before = set(console_windows())
    p = subprocess.Popen([exe] + args, cwd=cwd or os.path.dirname(os.path.abspath(exe)),
                         creationflags=0x00000010, close_fds=True)
    time.sleep(2.5)

    new = [h for h in console_windows() if h not in before]
    print("pid", p.pid, "alive", p.poll() is None, "windows", len(new))
    if not new:
        print("no console window")
        p.terminate()
        return 1
    ok, info = capture(new[0], out)
    print("capture:", ok, info)

    ctypes.windll.kernel32.FreeConsole()
    subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"],
                   capture_output=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
