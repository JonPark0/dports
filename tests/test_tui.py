#!/usr/bin/env python3
"""Drive dports' full-screen views in a pseudo-terminal (no Docker needed).

Covers `dports update` (check, select, pull, recreate), `dports -I`, the
Zsh and Fish front ends, and Zsh tab completion. Uses tests/fake-docker and
only the Python standard library. Usage: python3 tests/test_tui.py
"""
import fcntl, os, pty, re, select, shutil, struct, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KEYS = {"down": b"\x1b[B", "up": b"\x1b[A", "right": b"\x1b[C", "left": b"\x1b[D",
        "enter": b"\r", "esc": b"\x1b", "tab": b"\t", "space": b" "}
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[=>]|\r")
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + name)
    if not ok:
        fails += 1
        for line in detail.splitlines()[-25:]:
            print("        | " + line)


class Term:
    """A program running in a pty; collects everything it writes."""

    def __init__(self, argv, env, rows=24, cols=100):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.out = b""
        self.mark = 0

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.out += os.read(self.fd, 65536)
                except OSError:
                    return

    def send(self, *keys, wait=0.7):
        for k in keys:
            self.mark = len(self.out)
            os.write(self.fd, KEYS.get(k, k.encode()))
            self.pump(wait)

    def since_mark(self):
        return ANSI.sub("", self.out[self.mark:].decode(errors="replace"))

    def text(self):
        return ANSI.sub("", self.out.decode(errors="replace"))

    def after_fullscreen(self):
        raw = self.out.decode(errors="replace")
        i = raw.rfind("\x1b[?1049l")
        return ANSI.sub("", raw[i + 8:]) if i >= 0 else ""

    def finish(self, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.2)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        os.kill(self.pid, 9)
        os.waitpid(self.pid, 0)
        return None


def setup():
    work = tempfile.mkdtemp()
    for d in ("bin", "state", "srv/site", "srv/my app", "home"):
        os.makedirs(os.path.join(work, d))
    os.symlink(os.path.join(HERE, "fake-docker"), os.path.join(work, "bin", "docker"))
    env = dict(os.environ, PATH=work + "/bin:" + os.environ["PATH"], FAKE_STATE=work + "/state",
               FAKE_ROOT=work + "/srv", TERM="xterm-256color", LANG="C.UTF-8", HOME=work + "/home",
               DPORTS_ENGINES="docker")  # only the fake docker, whatever else is installed
    return work, env


def read_state(work, name):
    p = os.path.join(work, "state", name)
    return open(p).read().split() if os.path.exists(p) and name != "compose" else \
        (open(p).read().splitlines() if os.path.exists(p) else [])


def test_update():
    print("dports update (full screen)")
    work, env = setup()
    t = Term(["bash", ROOT + "/dports.bash", "update"], env)
    t.pump(2.5)
    screen = t.text()
    check("check results appear in the checklist", "nginx:latest" in screen and "update" in screen, screen)
    check("only images with updates start selected",
          re.search(r"\[x\] nginx:latest", screen) is not None
          and re.search(r"\[x\] (myapp|mysite|registry)", screen) is None, screen)
    check("outdated containers are offered", "r recreate (2)" in screen, screen)
    t.send("enter", wait=2)
    screen = t.since_mark()
    check("Enter pulls and opens the recreate screen",
          "site/web" in screen and "Recreate all" in screen, screen)
    check("a container outside Compose is marked manual", re.search(r"db +manual", screen) is not None, screen)
    t.send("enter", wait=1.5)
    check("Enter recreates the service under the cursor",
          re.search(r"myapp/app +recreated", t.since_mark()) is not None, t.since_mark())
    t.send("tab", "right", "right", "enter", wait=1.5)
    check("the Recreate all button recreates the rest",
          re.search(r"site/web +recreated", t.since_mark()) is not None, t.since_mark())
    t.send("q", wait=1)
    code = t.finish()
    summary = t.after_fullscreen()
    check("exit leaves a summary on the normal screen",
          "Pulled" in summary and "nginx:latest  updated" in summary and "site/proxy  recreated" in summary, summary)
    check("pulled only the selected image", read_state(work, "pulls") == ["nginx:latest"], str(read_state(work, "pulls")))
    calls = read_state(work, "compose")
    check("compose ran in each project directory",
          sorted(calls) == sorted([work + "/srv/my app|myapp|app", work + "/srv/site|site|proxy",
                                   work + "/srv/site|site|web"]), str(calls))
    check("exit status 0", code == 0, str(code))
    shutil.rmtree(work)

    work, env = setup()
    t = Term(["bash", ROOT + "/dports.bash", "update"], env)
    t.pump(2.5)
    t.send("q", wait=1)
    code = t.finish()
    check("q in the checklist cancels without pulling",
          "Cancelled." in t.after_fullscreen() and not read_state(work, "pulls"), t.after_fullscreen())

    t = Term(["bash", ROOT + "/dports.bash", "update"], env)
    t.pump(2.5)
    t.mark = len(t.out)
    t.send("\x03", wait=1)
    code = t.finish()
    tail = t.out.decode(errors="replace")
    check("Ctrl+C restores the screen and cursor", tail.rfind("\x1b[?1049l") > tail.rfind("\x1b[?1049h")
          and "\x1b[?25h" in tail[tail.rfind("\x1b[?1049h"):], repr(tail[-200:]))
    shutil.rmtree(work)


def test_browse():
    print("dports -I (experimental browser)")
    work, env = setup()
    t = Term(["bash", ROOT + "/dports.bash", "-I"], env, rows=20)
    t.pump(2)
    screen = t.text()
    check("lists the published ports", all(p in screen for p in ("443", "3000", "5432", "8080")), screen)
    check("details of the selected container", "compose: site/proxy" in screen, screen)
    t.send("/", "w", "e", "b", "enter")
    check("search filters the rows", "1/4 rows" in t.since_mark(), t.since_mark())
    t.send("l", wait=1)
    logs = t.since_mark()
    check("l shows the logs, escape sequences made visible", "Logs: web" in logs and "^[[31mred" in logs, logs)
    t.send("q")
    t.send("R")
    check("R asks before restarting", "Restart web? (y/n)" in t.since_mark(), t.since_mark())
    t.send("y", wait=1.5)
    check("y restarts the container", read_state(work, "restarts") == ["web"], str(read_state(work, "restarts")))
    t.send("esc", "esc", wait=1)
    code = t.finish()
    check("Esc clears the search, then quits", code == 0, str(code))
    shutil.rmtree(work)


def test_shells():
    for shell, argv in (("zsh", ["zsh", "-f", "-c", "source %s/dports.zsh; dports update" % ROOT]),
                        ("fish", ["fish", "--no-config", "-c", "source %s/dports.fish; dports update" % ROOT])):
        if not shutil.which(shell):
            print("%s not installed; skipping its tests" % shell)
            continue
        print("%s front end" % shell)
        work, env = setup()
        t = Term(argv, env)
        t.pump(2.5)
        check("%s runs the full-screen update" % shell, "dports update" in t.text(), t.text())
        t.send("enter", wait=2)
        t.send("A", wait=1.5)
        t.send("q", wait=1)
        t.finish()
        check("%s: pull and recreate work through the wrapper" % shell,
              "site/web    recreated" in t.after_fullscreen(), t.after_fullscreen())
        shutil.rmtree(work)

    if not shutil.which("zsh"):
        return
    print("zsh completion")
    work, env = setup()
    zdot = work + "/home"
    with open(zdot + "/.zshrc", "w") as f:
        f.write("PS1='%% '\nautoload -Uz compinit && compinit -u -d %s/.zcompdump\nsource %s/dports.zsh\n"
                % (zdot, ROOT))
    env = dict(env, ZDOTDIR=zdot, TERM="xterm")
    for typed, want in (("dports --verb\t", "dports --verbose"),
                        ("dports update --re\t", "dports update --recreate"),
                        ("dports --interac\t", "dports --interactive")):
        t = Term(["zsh", "-i"], env)
        t.pump(1.5)
        t.send(typed, wait=1.5)
        line = t.since_mark()
        os.write(t.fd, b"\x03exit\r")
        t.finish(3)
        check("completes %r" % typed.strip(), want in line, line)
    shutil.rmtree(work)


test_update()
test_browse()
test_shells()
print()
if fails:
    print("%d test(s) failed" % fails)
    sys.exit(1)
print("All tests passed")
