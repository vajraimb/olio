"""Drive the olio IDE through its features and screenshot each state.

Usage: python drive_ide.py <exe> <file> <outdir>
"""

import ctypes, ctypes.wintypes as wt, subprocess, sys, time, os
from PIL import ImageGrab

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

LOG_PATH = None


def log(*a):
    line = " ".join(str(x) for x in a)
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


def client_box(hwnd):
    r = RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    tl = POINT(r.Left, r.Top)
    u32.ClientToScreen(hwnd, ctypes.byref(tl))
    return (tl.x, tl.y, tl.x + (r.Right - r.Left), tl.y + (r.Bottom - r.Top))


KEYUP = 0x0002
VK_CONTROL = 0x11


def tap(vk):
    scan = u32.MapVirtualKeyW(vk, 0)
    u32.keybd_event(vk, scan, 0, 0)
    u32.keybd_event(vk, scan, KEYUP, 0)
    time.sleep(0.03)


def ctrl(ch):
    scan = u32.MapVirtualKeyW(VK_CONTROL, 0)
    u32.keybd_event(VK_CONTROL, scan, 0, 0)
    time.sleep(0.12)
    tap(ord(ch.upper()))
    time.sleep(0.12)
    u32.keybd_event(VK_CONTROL, scan, KEYUP, 0)
    time.sleep(0.15)


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
            mods.append(0xA0)
        scan = u32.MapVirtualKeyW(vk, 0)
        for m in mods:
            u32.keybd_event(m, u32.MapVirtualKeyW(m, 0), 0, 0)
        u32.keybd_event(vk, scan, 0, 0)
        time.sleep(0.012)
        u32.keybd_event(vk, scan, KEYUP, 0)
        for m in reversed(mods):
            u32.keybd_event(m, u32.MapVirtualKeyW(m, 0), KEYUP, 0)
        time.sleep(0.025)


def focus_window(hwnd):
    """Windows only lets a process steal the foreground under specific rules,
    so attach to the target's input queue and, failing that, click its title bar."""
    for _ in range(4):
        tid = u32.GetWindowThreadProcessId(hwnd, None)
        my_tid = k32.GetCurrentThreadId()
        u32.AttachThreadInput(my_tid, tid, True)
        u32.ShowWindow(hwnd, 9)  # SW_RESTORE
        u32.SetForegroundWindow(hwnd)
        u32.BringWindowToTop(hwnd)
        u32.AttachThreadInput(my_tid, tid, False)
        time.sleep(0.4)
        if u32.GetForegroundWindow() == hwnd:
            return True

    # Fallback: a click on the title bar always transfers activation.
    box = client_box(hwnd)
    x = (box[0] + box[2]) // 2
    y = box[1] - 12
    u32.SetCursorPos(x, y)
    time.sleep(0.15)
    u32.mouse_event(0x0002, 0, 0, 0, 0)  # LEFTDOWN
    time.sleep(0.05)
    u32.mouse_event(0x0004, 0, 0, 0, 0)  # LEFTUP
    time.sleep(0.5)
    return u32.GetForegroundWindow() == hwnd


def main():
    global LOG_PATH
    exe, target, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    mode = sys.argv[4] if len(sys.argv) > 4 else "main"
    workdir = sys.argv[5] if len(sys.argv) > 5 else os.path.dirname(os.path.abspath(exe))
    LOG_PATH = os.path.join(outdir, "drive.log")
    open(LOG_PATH, "w").close()

    # Launch + steal focus, retrying: Windows only grants the foreground under
    # rules we cannot always satisfy, and this is a throwaway demo window.
    p = None
    hwnd = None
    for attempt in range(4):
        before = set(console_windows())
        argv = [exe] if target == "-" else [exe, target]
        p = subprocess.Popen(argv, cwd=workdir,
                             creationflags=0x00000010, close_fds=True)
        time.sleep(3.0)
        new = [h for h in console_windows() if h not in before]
        log("attempt", attempt, "pid", p.pid, "alive", p.poll() is None,
            "windows", len(new))
        if not new:
            p.terminate()
            p = None
            continue
        hwnd = new[0]
        for _ in range(4):
            u32.SetForegroundWindow(hwnd)
            time.sleep(0.3)
            if u32.GetForegroundWindow() == hwnd:
                break
        if u32.GetForegroundWindow() == hwnd or focus_window(hwnd):
            break
        log("focus refused, retrying")
        p.terminate()
        time.sleep(1.0)
        p = None

    if p is None or hwnd is None:
        log("ABORT: could not get a focused window")
        return
    log("focused ok")

    shot_n = [0]

    def shot(name, wait=0.6):
        time.sleep(wait)
        shot_n[0] += 1
        path = os.path.join(outdir, "%02d_%s.png" % (shot_n[0], name))
        ImageGrab.grab(bbox=client_box(hwnd), all_screens=True).save(path)
        log("shot", path)

    shot("editor")

    if mode == "error":
        ctrl("r")
        shot("build_error", 9.0)
        tap(0x0D)  # enter jumps to the first diagnostic
        shot("jumped_to_error", 1.0)
        log("alive before quit:", p.poll() is None)
        for _ in range(4):
            ctrl("q")
            time.sleep(0.6)
        log("alive after quit:", p.poll() is None)
        if p.poll() is None:
            p.terminate()
        return

    ctrl("b")
    shot("sidebar")

    tap(0x23)  # End -> last entry in the tree
    time.sleep(0.3)
    tap(0x0D)  # enter -> open it
    shot("opened_from_tree", 1.0)

    ctrl("b")  # hide tree, back to the editor
    time.sleep(0.3)

    ctrl("r")  # build
    shot("build", 8.0)

    ctrl("e")  # close the build panel
    time.sleep(0.3)

    ctrl("n")  # next buffer
    shot("tabs")

    log("alive before quit:", p.poll() is None)
    ctrl("q")
    time.sleep(0.5)
    ctrl("q")
    time.sleep(0.5)
    ctrl("q")
    time.sleep(1.0)
    log("alive after quit:", p.poll() is None)
    if p.poll() is None:
        p.terminate()
        log("terminated by harness")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        import traceback
        with open(os.path.join(sys.argv[3], "drive_crash.log"), "a") as f:
            f.write(traceback.format_exc())
        raise
