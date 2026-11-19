"""Launch olio, verify it renders, then type into it via (focus-guarded) key
injection, save with Ctrl-S, quit with Ctrl-Q, and check the file on disk."""

import ctypes, ctypes.wintypes as wt, subprocess, sys, time, os
from PIL import ImageGrab

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

LOG = []
LOG_PATH = None


def log(*a):
    line = " ".join(str(x) for x in a)
    LOG.append(line)
    if LOG_PATH:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
            f.flush()


class RECT(ctypes.Structure):
    _fields_ = [("Left", ctypes.c_long), ("Top", ctypes.c_long),
                ("Right", ctypes.c_long), ("Bottom", ctypes.c_long)]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def console_windows():
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


def client_box(hwnd):
    r = RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    tl = POINT(r.Left, r.Top)
    u32.ClientToScreen(hwnd, ctypes.byref(tl))
    return (tl.x, tl.y, tl.x + (r.Right - r.Left), tl.y + (r.Bottom - r.Top))


def shot(hwnd, path):
    u32.SetForegroundWindow(hwnd)
    time.sleep(0.5)
    ImageGrab.grab(bbox=client_box(hwnd), all_screens=True).save(path)
    log("saved", path)


KEYUP = 0x0002


def tap(vk):
    scan = u32.MapVirtualKeyW(vk, 0)
    u32.keybd_event(vk, scan, 0, 0)
    u32.keybd_event(vk, scan, KEYUP, 0)
    time.sleep(0.02)


def type_text(text):
    for ch in text:
        if ch == "\r":
            tap(0x0D)
            continue
        packed = u32.VkKeyScanW(ord(ch))
        vk = packed & 0xFF
        shift = (packed >> 8) & 0xFF
        if vk == 0xFF:
            log("no vk for", repr(ch))
            continue
        mods = []
        if shift & 1:
            mods.append(0xA0)  # VK_LSHIFT
        if shift & 2:
            mods.append(0xA2)  # VK_LCONTROL
        if shift & 4:
            mods.append(0xA4)  # VK_LMENU
        scan = u32.MapVirtualKeyW(vk, 0)
        for m in mods:
            u32.keybd_event(m, u32.MapVirtualKeyW(m, 0), 0, 0)
        u32.keybd_event(vk, scan, 0, 0)
        time.sleep(0.01)
        u32.keybd_event(vk, scan, KEYUP, 0)
        for m in reversed(mods):
            u32.keybd_event(m, u32.MapVirtualKeyW(m, 0), KEYUP, 0)
        time.sleep(0.02)


def ctrl(ch):
    scan = u32.MapVirtualKeyW(0x11, 0)
    u32.keybd_event(0x11, scan, 0, 0)
    time.sleep(0.05)
    tap(ord(ch.upper()))
    time.sleep(0.05)
    u32.keybd_event(0x11, scan, KEYUP, 0)
    time.sleep(0.1)


def focused(hwnd):
    return u32.GetForegroundWindow() == hwnd


def main():
    global LOG_PATH
    exe, target, logpath = sys.argv[1], sys.argv[2], sys.argv[3]
    LOG_PATH = logpath
    open(logpath, "w").close()
    here = os.path.dirname(os.path.abspath(exe))
    log("start", exe, target)

    before = set(console_windows())
    p = subprocess.Popen([exe, target], cwd=here, creationflags=0x00000010, close_fds=True)
    time.sleep(2.5)
    new = [h for h in console_windows() if h not in before]
    log("pid", p.pid, "alive", p.poll() is None, "windows", len(new))
    if not new:
        log("no console window; abort")
        p.terminate()
        return
    hwnd = new[0]

    shot(hwnd, os.path.join(here, "shot_1_welcome.png"))

    for attempt in range(5):
        u32.SetForegroundWindow(hwnd)
        time.sleep(0.4)
        if focused(hwnd):
            break
    if not focused(hwnd):
        log("ABORT: could not bring olio window to foreground; not injecting keys")
        p.terminate()
        return
    log("window focused, injecting keys")

    type_text("hello from olio\r")
    type_text("    indented odin line\r")
    time.sleep(0.5)
    shot(hwnd, os.path.join(here, "shot_2_typed.png"))

    ctrl("s")
    time.sleep(0.6)
    shot(hwnd, os.path.join(here, "shot_3_saved.png"))

    ctrl("q")
    time.sleep(1.0)
    log("after Ctrl-Q alive:", p.poll() is None)

    if p.poll() is None:
        log("still alive; terminating")
        p.terminate()

    try:
        data = open(os.path.join(here, target), "rb").read()
        log("file bytes:", repr(data))
    except Exception as e:
        log("read error", e)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        import traceback
        with open(sys.argv[3] if len(sys.argv) > 3 else "crash.log", "a") as f:
            f.write(traceback.format_exc())
        raise
