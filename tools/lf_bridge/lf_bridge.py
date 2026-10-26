"""Living Front bridge (0.58): Project Zomboid <-> a local language model. Text only, no Chasm.

Project Zomboid's Lua can't make web requests, so this helper does it for Living Front:

  * It runs the language model itself: llama.cpp's llama-server with a GGUF model (by default
    the copies Chasm downloaded; or put llama-server.exe and a .gguf in this folder, or name them
    in lf_bridge.json). It starts the model when Project Zomboid is running and stops it when the
    game has been closed for a minute, so it only uses your graphics card while you play.
  * The mod drops requests in Zomboid\\Lua\\LivingFront\\chasm\\out\\: a soldier to answer
    ("talk" - he is played from the life Living Front gave him), a conversation to sum up when
    it ends ("summarize"), or a radio report to word ("report"). The answer goes to ...\\in\\.
  * Without a model it answers with the words the mod sent along (plain, but never silent).

Standard library only (Python 3.9+). Run it with run_lf_bridge.bat, or:
    python lf_bridge.py [--once] [--zomboid DIR] [--verbose] [--no-model]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

VERSION = "0.58.0"
HERE = Path(__file__).resolve().parent
APPDATA = Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming")))
CHASM_MODELS = APPDATA / "com.chasm.app" / "data" / "default-user" / "models"

CFG = {
    "llm": "http://127.0.0.1:5001",
    "port": 5001,
    "llama_server": None,       # path to llama-server.exe (None: look for it)
    "model": None,              # path to a .gguf (None: look for one)
    "gpu_layers": 999,          # all on the graphics card; lower it (or 0) if the game stutters
    "ctx": 8192,
    "game_exe": ["ProjectZomboid64.exe", "ProjectZomboid32.exe", "ProjectZomboid.exe"],
    "stop_after": 60,           # seconds after the game closes before the model is stopped
    "timeout": 60,
    "talk_max_tokens": 160,
    "summary_max_tokens": 90,
    "report_max_tokens": 70,
    "temperature": 0.85,
}

LOG_PATH = HERE / "lf_bridge.log"
VERBOSE = False


def log(msg: str) -> None:
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def vlog(msg: str) -> None:
    if VERBOSE:
        log(msg)


def load_settings() -> None:
    p = HERE / "lf_bridge.json"
    if p.exists():
        try:
            CFG.update(json.loads(p.read_text(encoding="utf-8")))
            log(f"settings from {p.name}")
        except (OSError, ValueError) as e:
            log(f"couldn't read {p.name}: {e}")
    CFG["llm"] = f"http://127.0.0.1:{CFG['port']}"


def http_json(url: str, body: dict | None = None, timeout: float = 10) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="GET" if body is None else "POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8")) if raw else {}


# ---- the game folder ------------------------------------------------------------------------------

class Mailbox:
    def __init__(self, zomboid: Path):
        self.root = zomboid / "Lua" / "LivingFront" / "chasm"
        self.out = self.root / "out"
        self.inn = self.root / "in"
        for d in (self.out, self.inn):
            d.mkdir(parents=True, exist_ok=True)
        self.n = 0

    def write_status(self, llm: str) -> None:
        self.n += 1
        text = f"alive={self.n}\nversion={VERSION}\nllm={llm}\ntts=off\n"
        tmp = self.root / "bridge.tmp"
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, self.root / "bridge.txt")

    def requests(self) -> list[Path]:
        def num(p: Path) -> int:
            tail = p.stem.split("_")[-1]
            return int(tail) if tail.isdigit() else 0
        return sorted(self.out.glob("req_*.json"), key=num)

    def answer(self, rid: int, fields: dict) -> None:
        def esc(v) -> str:
            return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        tmp = self.inn / f"res_{rid}.tmp"
        tmp.write_text("".join(f"{k}={esc(v)}\n" for k, v in fields.items()), encoding="utf-8")
        os.replace(tmp, self.inn / f"res_{rid}.txt")

    def clean(self) -> None:
        now = time.time()
        for p in self.inn.glob("res_*.txt"):
            try:
                if p.read_text(encoding="utf-8", errors="replace").startswith("done=1") or now - p.stat().st_mtime > 300:
                    p.unlink()
            except OSError:
                pass


# ---- the model ---------------------------------------------------------------------------------------------

def game_running() -> bool:
    if os.name != "nt":
        return True
    for exe in CFG["game_exe"]:
        try:
            out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {exe}", "/NH"], capture_output=True, text=True,
                                 timeout=5, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if exe.lower() in out.lower():
            return True
    return False


def find_files() -> tuple[Path | None, Path | None]:
    exe = Path(CFG["llama_server"]) if CFG.get("llama_server") else None
    model = Path(CFG["model"]) if CFG.get("model") else None
    if not exe:
        for cand in (HERE / "llama" / "llama-server.exe", HERE / "llama-server.exe",
                     CHASM_MODELS / "llamacpp" / "llama-server.exe"):
            if cand.exists():
                exe = cand
                break
    if not model:
        for folder in (HERE, HERE / "models", CHASM_MODELS / "llm"):
            ggufs = sorted(folder.glob("*.gguf")) if folder.is_dir() else []
            if ggufs:
                model = ggufs[0]
                break
    return exe, model


class Model:
    """llama-server, started and stopped by the bridge."""

    def __init__(self, use: bool) -> None:
        self.use = use
        self.proc: subprocess.Popen | None = None
        self.state = "off"
        self.ready_at = 0.0
        self.failed_args = False

    def up(self) -> bool:
        try:
            http_json(CFG["llm"] + "/health", timeout=2)
            return True
        except (OSError, ValueError, urllib.error.URLError):
            return False

    def start(self) -> None:
        if self.proc:
            return
        if self.up():
            if self.state != "ok":
                log("a language model is already running on port " + str(CFG["port"]) + " - using it")
            self.state = "ok"     # (one is already running - Chasm's, or one you started)
            return
        if not self.use:
            self.state = "off"
            return
        exe, model = find_files()
        if not exe or not model:
            if self.state != "missing":
                log(f"no language model to run: llama-server {'found' if exe else 'NOT found'}, "
                    f"model {'found' if model else 'NOT found'} - put them in {HERE} or name them in lf_bridge.json")
            self.state = "missing"
            return
        args = [str(exe), "-m", str(model), "--host", "127.0.0.1", "--port", str(CFG["port"]),
                "-ngl", str(CFG["gpu_layers"]), "-c", str(CFG["ctx"]), "-np", "1"]
        if not self.failed_args:
            args += ["--jinja", "--cache-reuse", "256", "--reasoning-budget", "0"]
        logf = open(HERE / "llama_server.log", "ab")
        log(f"starting the language model: {model.name} ({CFG['gpu_layers']} layers on the graphics card)")
        self.proc = subprocess.Popen(args, cwd=str(exe.parent), stdout=logf, stderr=subprocess.STDOUT,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.state = "starting"
        self.ready_at = time.time()

    def stop(self) -> None:
        if self.proc:
            log("game closed - stopping the language model")
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        if self.state != "missing":
            self.state = "off"

    def check(self) -> None:
        if self.proc and self.proc.poll() is not None:
            code = self.proc.returncode
            self.proc = None
            if time.time() - self.ready_at < 20 and not self.failed_args:
                log(f"the language model exited at once (code {code}) - trying again with plain settings")
                self.failed_args = True
                self.start()
                return
            log(f"the language model stopped (code {code}) - see llama_server.log")
            self.state = "off"
            return
        if self.state == "starting" and self.up():
            log(f"the language model is ready ({time.time() - self.ready_at:.0f} s)")
            self.state = "ok"

    def chat(self, messages: list[dict], max_tokens: int) -> str:
        body = {"messages": messages, "max_tokens": max_tokens, "temperature": CFG["temperature"],
                "top_p": 0.95, "repeat_penalty": 1.1, "cache_prompt": True, "stream": False}
        res = http_json(CFG["llm"] + "/v1/chat/completions", body, timeout=CFG["timeout"])
        return clean(res["choices"][0]["message"]["content"])


def clean(text: str) -> str:
    text = (text or "").strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    text = re.sub(r"\*[^*]{1,80}\*", "", text)            # (*stage directions*)
    text = re.sub(r"^\s*[\w .'-]{1,40}:\s*", "", text) if re.match(r"^\s*(Pvt|Cpl|Sgt|SSgt|Lt)\.?\s", text) else text
    text = " ".join(l.strip() for l in text.splitlines() if l.strip())
    return text.strip().strip('"').strip()[:600]


# ---- prompts ------------------------------------------------------------------------------------------------

SIDE = {"GER": ("German", "the Wehrmacht"), "SOV": ("Soviet", "the Red Army")}
RANKS = {"PVT": "private", "CPL": "corporal", "SGT": "sergeant", "SSG": "staff sergeant", "LT": "lieutenant"}
TRUST = {-3: "He resents the officer.", -2: "He doesn't trust the officer.", -1: "He's wary of the officer.",
         0: "He doesn't know the officer well.", 1: "He's warming to the officer.", 2: "He trusts the officer.",
         3: "He'd follow the officer anywhere."}


def character(req: dict) -> str:
    """Who he is, written about him (the third person keeps a small model from mixing 'you' and 'he')."""
    s = req.get("soldier") or {}
    p = req.get("persona") or {}
    name = s.get("name", "a soldier")
    adj, army = SIDE.get(s.get("faction"), ("", "the army"))
    rank = RANKS.get(s.get("rank") or "", "soldier")
    lines = [f"You are playing {name}: {p.get('age', 'about 25')} years old, a {adj} {rank} in {army}, serving in "
             f"{s.get('unit') or 'his unit'}" + (f" of {s.get('platoon')}" if s.get("platoon") else "") + "."]
    if p:
        lines.append(f"He comes from {p.get('home')}. Before the war he was {p.get('job')}. He has {p.get('family')}. "
                     f"He {p.get('past')}.")
        lines.append(f"His nature: {p.get('traits')}. About the war, he {p.get('war')}.")
        lines.append(f"What he wants most: {p.get('want')}. What he fears: {p.get('fear')}.")
        lines.append(f"His secret (he lets it slip only if he trusts the officer, or is pushed hard): {p.get('secret')}.")
        if p.get("friend"):
            lines.append(p["friend"][0].upper() + p["friend"][1:] + ".")
        if p.get("rival"):
            lines.append("He " + p["rival"][3:] + "." if p["rival"].startswith("he ") else p["rival"] + ".")
        lines.append(f"How he talks: {p.get('speech')}. Lines in his voice:")
        for ex in p.get("examples") or []:
            lines.append(f'  "{ex}"')
    state = [f"His morale right now: {s.get('morale', 'steady')}."]
    if s.get("wounded"):
        state.append("He is wounded and in pain.")
    if s.get("lost"):
        state.append(f"He has lost {s['lost']} comrades.")
    if s.get("kills"):
        state.append(f"He has killed {s['kills']} of the enemy.")
    if s.get("doing"):
        state.append(f"Right now his unit is {s['doing']}.")
    lines.append(" ".join(state))
    mems = req.get("memories") or []
    if mems:
        lines.append("What he has seen lately ('your squad' there means his own squad):")
        lines += [f"- {m}" for m in mems[:6]]
    try:
        trust = int(p.get("trust") or 0)
    except (TypeError, ValueError):
        trust = 0
    lines.append("The officer talking to him: " + TRUST.get(max(-3, min(3, trust)), ""))
    notes = p.get("notes") or []
    if notes:
        lines.append("From earlier talks with this officer:")
        lines += [f"- {n}" for n in notes[-4:]]
    return "\n".join(lines)


TALK_RULES = ("An officer of his own army is talking to him face to face, in a pause in the fighting. Reply as "
              "him, in the first person, and stay in character the whole time. Answer in English, as he would say it out loud: "
              "usually one to three sentences, more only if he is the talkative sort or it's a story worth telling. "
              "No narration, no actions in asterisks, no quotation marks round your words. Talk about yourself, your "
              "home, your mates and the war in your own way when asked. Only speak of events you have seen or that are "
              "listed above; never invent battles, deaths or names of men in his unit. If he doesn't know, he says so in "
              "his own way. Don't repeat earlier answers word for word.")


def talk_messages(req: dict) -> list[dict]:
    msgs = [{"role": "system", "content": character(req) + "\n\n" + TALK_RULES}]
    hist = req.get("history")
    for h in hist if isinstance(hist, list) else []:
        if isinstance(h, dict) and h.get("you") and h.get("him"):
            msgs.append({"role": "user", "content": h["you"]})
            msgs.append({"role": "assistant", "content": h["him"]})
    msgs.append({"role": "user", "content": req.get("player_text") or ""})
    return msgs


def summary_messages(req: dict) -> list[dict]:
    s = req.get("soldier") or {}
    hist = req.get("history") if isinstance(req.get("history"), list) else []
    talk = "\n".join(f"Officer: {h.get('you')}\n{s.get('name', 'Soldier')}: {h.get('him')}" for h in hist if isinstance(h, dict))
    sys_msg = (f"You keep notes for {s.get('name', 'a soldier')}. Read the conversation below between him and an officer. "
               "Reply in exactly this form, on two lines:\n"
               "NOTE: <one or two short sentences, written about him in the third person, of what was said that he would "
               "remember - facts he learned or told, promises, insults, kindness>\n"
               "TRUST: <+1 if he now thinks better of the officer, -1 if worse, 0 if no change>")
    return [{"role": "system", "content": sys_msg}, {"role": "user", "content": talk}]


def report_messages(req: dict) -> list[dict]:
    s = req.get("speaker") or {}
    adj, army = SIDE.get(s.get("faction"), ("", "the army"))
    sys_msg = (f"You are {s.get('name', 'a radio operator')}, the radio operator of {req.get('unit', 'your platoon')}, "
               f"{adj} {army}. Send a short situation report over the radio to company headquarters. Use only the "
               "facts given - never add events, numbers or places. One or two terse sentences in English, the way a "
               "radio operator speaks, callsign first, ending with 'Over.' No quotation marks.")
    return [{"role": "system", "content": sys_msg},
            {"role": "user", "content": "Facts:\n- " + "\n- ".join(req.get("facts") or [])}]


# ---- the bridge -------------------------------------------------------------------------------------------

class Bridge:
    def __init__(self, zomboid: Path, use_model: bool) -> None:
        self.box = Mailbox(zomboid)
        self.model = Model(use_model)
        self.last_beat = 0.0
        self.last_game = 0.0
        self.game_seen = 0.0

    def handle(self, path: Path) -> None:
        try:
            req = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError) as e:
            log(f"bad request {path.name}: {e}")
            path.unlink(missing_ok=True)
            return
        path.unlink(missing_ok=True)
        rid = int(req.get("id") or 0)
        kind = req.get("kind")
        fallback = req.get("fallback") or ""
        t0 = time.time()
        fields = {"status": "ok", "text": fallback, "worded": "no", "voiced": "no"}
        if self.model.state == "ok":
            try:
                if kind == "talk":
                    fields["text"] = self.model.chat(talk_messages(req), CFG["talk_max_tokens"]) or fallback
                elif kind == "report":
                    fields["text"] = self.model.chat(report_messages(req), CFG["report_max_tokens"]) or fallback
                elif kind == "summarize":
                    raw = self.model.chat(summary_messages(req), CFG["summary_max_tokens"])
                    note = re.search(r"NOTE:\s*(.+?)(?:TRUST:|$)", raw, re.S)
                    trust = re.search(r"TRUST:\s*([+-]?\d)", raw)
                    fields["text"] = (note.group(1).strip() if note else raw).strip()[:300] or fallback
                    fields["trust"] = trust.group(1) if trust else "0"
                fields["worded"] = "yes" if fields["text"] != fallback else "no"
            except Exception as e:  # noqa: BLE001
                log(f"the language model didn't answer ({e}) - Living Front's own words this time")
                if not self.model.proc:
                    self.model.state = "off"        # (someone else's server went away: look again)
        log(f"{kind} #{rid} ({time.time() - t0:.1f} s, {'model' if fields['worded'] == 'yes' else 'plain'}): {fields['text'][:100]}")
        self.box.answer(rid, fields)

    def tick(self) -> None:
        now = time.time()
        if now - self.last_beat >= 1.0:
            self.last_beat = now
            self.box.write_status(self.model.state)
            self.box.clean()
            self.model.check()
        if now - self.last_game >= 5.0:
            self.last_game = now
            if game_running():
                self.game_seen = now
                self.model.start()
            elif self.model.proc and now - self.game_seen > CFG["stop_after"]:
                self.model.stop()
        # (While the model is loading - up to two minutes - requests wait for it rather than getting
        # plain answers.)
        if self.model.state == "starting" and now - self.model.ready_at < 120:
            return
        for p in self.box.requests():
            self.handle(p)

    def run(self, once: bool = False) -> None:
        log(f"Living Front bridge {VERSION} (text, no Chasm): game folder {self.box.root}")
        exe, model = find_files()
        log(f"llama-server: {exe or 'not found'}")
        log(f"model: {model or 'not found'}")
        try:
            while True:
                try:
                    self.tick()
                except Exception as e:  # noqa: BLE001
                    log(f"error: {e}")
                if once:
                    return
                time.sleep(0.2)
        finally:
            if not once:
                self.model.stop()


def main() -> None:
    global VERBOSE
    ap = argparse.ArgumentParser(description="Living Front bridge (text)")
    ap.add_argument("--zomboid", default=str(Path.home() / "Zomboid"))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--no-model", action="store_true", help="never start a language model (use one already running)")
    args = ap.parse_args()
    VERBOSE = args.verbose
    load_settings()
    Bridge(Path(args.zomboid), not args.no_model).run(once=args.once)


if __name__ == "__main__":
    main()
