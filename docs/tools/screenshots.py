#!/usr/bin/env python3
"""Render the README images from the real dports output.

Runs dports.bash in a pseudo-terminal against docs/tools/demo-docker,
captures the screen (pyte), and renders PNGs with Chromium (playwright).

Needs: python3 with pyte (pip install pyte), node with playwright and a
Chromium build. Usage (from the repository root):
    python3 docs/tools/screenshots.py
Writes docs/images/*.png.
"""
import fcntl, html, json, os, pty, select, shutil, struct, subprocess, tempfile, termios, time

import pyte

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "docs", "images")
KEYS = {"down": b"\x1b[B", "up": b"\x1b[A", "enter": b"\r", "tab": b"\t", "q": b"q"}

# Colors (GitHub dark)
BG, FG = "#0d1117", "#c9d1d9"
PALETTE = {"default": FG, "black": "#484f58", "red": "#ff7b72", "green": "#3fb950", "yellow": "#d29922",
           "brown": "#d29922",  # pyte's name for SGR 33
           "blue": "#58a6ff", "magenta": "#bc8cff", "cyan": "#39c5cf", "white": "#f0f6fc"}
REV_BG, REV_FG = "#264f78", "#ffffff"


class Session:
    def __init__(self, argv, rows, cols, env):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def key(self, name, wait=0.6):
        os.write(self.fd, KEYS.get(name, name.encode()))
        self.pump(wait)

    def html(self, last_row=None):
        """The screen as <pre> lines with colored spans (trailing blank lines dropped)."""
        rows = self.screen.buffer
        n = self.screen.lines
        while n > 0 and not "".join(rows[n - 1][x].data for x in range(self.screen.columns)).strip():
            n -= 1
        if last_row is not None:
            n = min(n, last_row)
        lines = []
        for y in range(n):
            out, run, style = [], "", None
            for x in range(self.screen.columns):
                c = rows[y][x]
                fg, bg = PALETTE.get(c.fg, FG), None
                if c.reverse:
                    fg, bg = REV_FG, REV_BG
                st = (fg, bg, c.bold)
                if st != style and run:
                    out.append(span(run, style)); run = ""
                style = st
                run += c.data
            if run:
                out.append(span(run.rstrip() if style[1] is None else run, style))
            lines.append("".join(out))
        return "\n".join(lines)

    def close(self):
        try:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def span(text, style):
    fg, bg, bold = style
    css = "color:%s;" % fg
    if bg:
        css += "background:%s;" % bg
    if bold:
        css += "font-weight:700;"
    return '<span style="%s">%s</span>' % (css, html.escape(text))


def window(title, body):
    return """<div class="win"><div class="bar"><i></i><i></i><i></i><span>%s</span></div>
<pre>%s</pre></div>""" % (html.escape(title), body)


PAGE = """<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:transparent;font-family:'JetBrains Mono','DejaVu Sans Mono',monospace;font-variant-ligatures:none;font-feature-settings:'liga' 0,'calt' 0}
.wrap{display:inline-block;padding:24px}
.win{background:%(bg)s;border:1px solid #30363d;border-radius:10px;box-shadow:0 12px 32px rgba(0,0,0,.35);overflow:hidden}
.bar{height:34px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;padding:0 14px;gap:8px}
.bar i{width:12px;height:12px;border-radius:50%%;background:#30363d;display:inline-block}
.bar span{margin-left:10px;color:#8b949e;font-size:13px}
pre{margin:0;padding:16px 18px 18px;color:%(fg)s;font-size:14px;line-height:1.45;font-family:inherit}
</style><div class="wrap">@@BODY@@</div>""" % {"bg": BG, "fg": FG}

BANNER = """<!doctype html><meta charset="utf-8"><style>
body{margin:0;width:1280px;height:640px;background:radial-gradient(1200px 600px at 85%% 20%%,#1f2a3a 0%%,#0d1117 60%%);
font-family:'JetBrains Mono','DejaVu Sans Mono',monospace;font-variant-ligatures:none;font-feature-settings:'liga' 0,'calt' 0;color:#c9d1d9;overflow:hidden}
.l{position:absolute;left:84px;top:150px;width:470px}
h1{margin:0;font-size:84px;letter-spacing:-2px;color:#f0f6fc}
h1 b{color:#3fb950}
p{font-size:23px;line-height:1.5;margin:22px 0 30px;color:#c9d1d9}
ul{list-style:none;padding:0;margin:0;font-size:17px;line-height:2.0;color:#8b949e}
ul li:before{content:"> ";color:#3fb950}
.r{position:absolute;left:640px;top:150px}
.win{background:%(bg)s;border:1px solid #30363d;border-radius:10px;box-shadow:0 24px 60px rgba(0,0,0,.5);overflow:hidden}
.bar{height:30px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;padding:0 12px;gap:7px}
.bar i{width:11px;height:11px;border-radius:50%%;background:#30363d;display:inline-block}
.bar span{margin-left:8px;color:#8b949e;font-size:12px}
pre{margin:0;padding:14px 16px;font-size:14px;line-height:1.45;font-family:inherit;color:%(fg)s}
</style>
<div class="l"><h1>dports<b>_</b></h1>
<p>Docker ports, Cloudflare Tunnel routes and image updates, in one terminal command.</p>
<ul><li>dports -t</li><li>dports update</li><li>dports -I</li></ul></div>
<div class="r">@@BODY@@</div>""" % {"bg": BG, "fg": FG}

ICON = """<!doctype html><meta charset="utf-8"><style>
body{margin:0;width:512px;height:512px;background:transparent;font-family:'JetBrains Mono','DejaVu Sans Mono',monospace;font-variant-ligatures:none;font-feature-settings:'liga' 0,'calt' 0}
.i{position:absolute;inset:24px;border-radius:96px;background:linear-gradient(160deg,#1f2a3a,#0d1117);
border:2px solid #30363d;display:flex;flex-direction:column;justify-content:center;padding-left:64px}
.a{font-size:132px;font-weight:800;color:#f0f6fc;letter-spacing:-6px}
.a b{color:#3fb950}
.p{font-size:46px;color:#39c5cf;margin-top:6px}
</style><div class="i"><div class="a">dp<b>_</b></div><div class="p">:443 -&gt;</div></div>"""

RENDER_JS = r"""
const { chromium } = require('playwright');
(async () => {
  const jobs = JSON.parse(process.argv[2]);
  const browser = await chromium.launch();
  for (const j of jobs) {
    const page = await browser.newPage({ deviceScaleFactor: j.scale || 2,
      viewport: { width: j.width || 1400, height: j.height || 900 } });
    await page.setContent(require('fs').readFileSync(j.html, 'utf8'));
    await page.evaluate(() => document.fonts.ready);
    if (j.full) {
      await page.screenshot({ path: j.png, omitBackground: !!j.transparent });
    } else {
      await (await page.$('.wrap')).screenshot({ path: j.png, omitBackground: true });
    }
    await page.close();
  }
  await browser.close();
})();
"""


def main():
    work = tempfile.mkdtemp()
    os.makedirs(os.path.join(work, "bin"))
    os.makedirs(os.path.join(work, "state"))
    os.symlink(os.path.join(ROOT, "docs", "tools", "demo-docker"), os.path.join(work, "bin", "docker"))
    # Compose project directories (shown as /srv/... in the images)
    for proj in ("app", "monitoring", "proxy", "edge"):
        os.makedirs(os.path.join(work, "srv", proj))
    env = dict(os.environ, PATH=work + "/bin:" + os.environ["PATH"], DEMO_STATE=work + "/state",
               DEMO_ROOT=work + "/srv", DPORTS_ENGINES="docker",
               TERM="xterm-256color", LANG="C.UTF-8", COLUMNS="", HOME=work)
    dports = os.path.join(ROOT, "dports.bash")
    shots = {}

    # 1. Port table and tunnel routes
    s = Session(["bash", "-c", "printf '$ dports -t\\n'; bash %s -t" % dports], 22, 112, env)
    s.pump(2.5)
    shots["ports"] = ("dports -t", s.html())
    s.close()
    # The banner shows the port table only, at a narrower width
    s = Session(["bash", dports], 12, 66, env)
    s.pump(2)
    banner_body = s.html()
    s.close()

    # 2-4. dports update: checking, choosing, recreating
    s = Session(["bash", dports, "update"], 20, 100, env)
    s.pump(0.45)
    shots["update-check"] = ("dports update", s.html())
    s.pump(3)
    s.key("down")
    shots["update"] = ("dports update", s.html())
    s.key("enter", wait=4.5)
    s.key("enter", wait=2)
    shots["recreate"] = ("dports update", s.html())
    s.close()

    # 5. Experimental browser
    for f in os.listdir(work + "/state"):
        os.remove(os.path.join(work, "state", f))
    s = Session(["bash", dports, "-I", "-t"], 20, 100, env)
    s.pump(2.5)
    for _ in range(3):
        s.key("down", wait=0.3)
    s.pump(1)
    shots["browse"] = ("dports -I -t", s.html())
    s.close()

    tmp = tempfile.mkdtemp()
    jobs = []
    for name, (title, body) in shots.items():
        body = body.replace(work + "/srv", "/srv")
        p = os.path.join(tmp, name + ".html")
        open(p, "w").write(PAGE.replace("@@BODY@@", window(title, body)))
        jobs.append({"html": p, "png": os.path.join(OUT, name + ".png")})
    # Banner (1280x640, also the repository's social preview) and icon
    p = os.path.join(tmp, "banner.html")
    open(p, "w").write(BANNER.replace("@@BODY@@", window("dports", banner_body)))
    jobs.append({"html": p, "png": os.path.join(OUT, "banner.png"), "full": True,
                 "width": 1280, "height": 640, "scale": 1})
    p = os.path.join(tmp, "icon.html")
    open(p, "w").write(ICON)
    jobs.append({"html": p, "png": os.path.join(OUT, "icon.png"), "full": True,
                 "width": 512, "height": 512, "scale": 1, "transparent": True})

    os.makedirs(OUT, exist_ok=True)
    js = os.path.join(tmp, "render.js")
    open(js, "w").write(RENDER_JS)
    subprocess.run(["node", js, json.dumps(jobs)], check=True, cwd=tmp,
                   env=dict(os.environ, NODE_PATH=os.environ.get("NODE_PATH", "")))
    for j in jobs:
        print("wrote", os.path.relpath(j["png"], ROOT))
    shutil.rmtree(work)
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
