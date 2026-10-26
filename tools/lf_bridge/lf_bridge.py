"""Living Front bridge: Project Zomboid <-> Chasm.

Project Zomboid's Lua can't make web requests or play sound files. This helper sits beside the
game and does both for Living Front:

  * The mod drops requests in Zomboid\\Lua\\LivingFront\\chasm\\out\\ (talk to a soldier, word a
    radio report). The bridge asks the language model Chasm runs (llama-server, an OpenAI-style
    API on 127.0.0.1:5001) for the words, asks Chasm for the voice (its TTS on 127.0.0.1:7341),
    writes the answer to ...\\chasm\\in\\ and plays the voice - from where the speaker stands,
    louder or quieter and left or right by the listener's position (state.json, which the mod
    rewrites twice a second), or over the radio for a report.
  * It writes Chasm's game heartbeat (%LOCALAPPDATA%\\chasm\\bridge\\runtime_heartbeat.json, with
    Project Zomboid's process id) so Chasm starts its models while the game runs and stops them
    when it closes, as it does for its own Fallout bridge.
  * It installs your reference voice clips (voices\\GER\\*.wav, voices\\SOV\\*.wav beside this
    file) into Chasm's voices folder, so its TTS can clone them, and gives each soldier one of
    his side's voices (always the same one).

Standard library only (Python 3.9+). Windows for sound; elsewhere it runs silent (for testing).
Run it with run_lf_bridge.bat, or: python lf_bridge.py [--once] [--zomboid DIR] [--verbose]
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import wave
from array import array
from pathlib import Path

try:
    import winsound  # type: ignore
except ImportError:  # (not Windows: no sound - the rest still works)
    winsound = None

VERSION = "0.57.0"
HERE = Path(__file__).resolve().parent
LOCALAPPDATA = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
APPDATA = Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming")))

CFG = {
    "chasm": os.environ.get("LF_CHASM_URL", "http://127.0.0.1:7341"),
    "llm": os.environ.get("LF_LLM_URL", "http://127.0.0.1:5001"),
    "chasm_bridge_root": Path(os.environ.get("CHASM_BRIDGE_ROOT", str(LOCALAPPDATA / "chasm" / "bridge"))),
    "chasm_app_dir": Path(os.environ.get("LF_CHASM_APP_DIR", str(APPDATA / "com.chasm.app"))),
    "game_exe": ("ProjectZomboid64.exe", "ProjectZomboid32.exe", "ProjectZomboid.exe"),
    "hear_range": 40.0,        # tiles: a voice fades to its quietest this far from you
    "min_volume": 0.12,
    "llm_timeout": 45,
    "tts_timeout": 60,
    "talk_max_tokens": 110,
    "report_max_tokens": 70,
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


# ---- HTTP -----------------------------------------------------------------------------------------

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
        self.alive_n = 0

    def write_status(self, llm: str, tts: str, chasm: str) -> None:
        self.alive_n += 1
        text = f"alive={self.alive_n}\nversion={VERSION}\nchasm={chasm}\nllm={llm}\ntts={tts}\n"
        tmp = self.root / "bridge.tmp"
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, self.root / "bridge.txt")

    def requests(self) -> list[Path]:
        files = [p for p in self.out.glob("req_*.json")]
        files.sort(key=lambda p: int(p.stem.split("_")[1]) if p.stem.split("_")[1].isdigit() else 0)
        return files

    def answer(self, rid: int, fields: dict) -> None:
        def esc(v: str) -> str:
            return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        text = "".join(f"{k}={esc(v)}\n" for k, v in fields.items())
        tmp = self.inn / f"res_{rid}.tmp"
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, self.inn / f"res_{rid}.txt")

    def clean(self) -> None:
        now = time.time()
        for p in self.inn.glob("res_*.txt"):
            try:
                body = p.read_text(encoding="utf-8", errors="replace")
                if body.startswith("done=1") or now - p.stat().st_mtime > 300:
                    p.unlink()
            except OSError:
                pass

    def state(self) -> dict:
        try:
            return json.loads((self.root / "state.json").read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            return {}


# ---- Chasm's heartbeat --------------------------------------------------------------------------------

def game_pid() -> int | None:
    if os.name != "nt":
        return None
    for exe in CFG["game_exe"]:
        try:
            out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {exe}", "/NH", "/FO", "CSV"],
                                 capture_output=True, text=True, timeout=5,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for line in out.splitlines():
            parts = [p.strip('"') for p in line.split('","')]
            if len(parts) > 1 and parts[1].strip('"').isdigit():
                return int(parts[1].strip('"'))
    return None


def write_heartbeat(pid: int | None) -> None:
    root: Path = CFG["chasm_bridge_root"]
    try:
        root.mkdir(parents=True, exist_ok=True)
        body = {"pid": pid, "game": "project-zomboid-living-front", "bridge": "lf_bridge " + VERSION,
                "time": time.time()}
        tmp = root / "runtime_heartbeat.tmp"
        tmp.write_text(json.dumps(body), encoding="utf-8")
        os.replace(tmp, root / "runtime_heartbeat.json")
    except OSError as e:
        vlog(f"heartbeat: {e}")


# ---- voices -------------------------------------------------------------------------------------------

def chasm_voices_dirs() -> list[Path]:
    """Where Chasm's TTS looks for voices: the active profile's voices folder, and the shared one."""
    app: Path = CFG["chasm_app_dir"]
    out = []
    profile = None
    for settings in (LOCALAPPDATA / "chasm" / "chasm.settings.json", app / "chasm.settings.json"):
        try:
            profile = json.loads(settings.read_text(encoding="utf-8")).get("profile") or profile
        except (OSError, ValueError):
            pass
    if profile:
        out.append(app / "profiles" / profile / "voices")
    out.append(app / "voices")
    return out


class Voices:
    """Your reference clips, one list per side; each soldier always gets the same one."""

    def __init__(self) -> None:
        self.by_side: dict[str, list[str]] = {}

    def install(self) -> None:
        src = HERE / "voices"
        self.by_side = {}
        targets = chasm_voices_dirs()
        for side in ("GER", "SOV", "ANY"):
            for wav in sorted((src / side).glob("*.wav")) if (src / side).is_dir() else []:
                name = f"LF {side} {wav.stem}"
                for t in targets:
                    try:
                        d = t / name
                        d.mkdir(parents=True, exist_ok=True)
                        dst = d / "reference.wav"
                        if not dst.exists() or dst.stat().st_size != wav.stat().st_size:
                            shutil.copyfile(wav, dst)
                    except OSError as e:
                        vlog(f"voice {name} -> {t}: {e}")
                self.by_side.setdefault(side, []).append(name)
        n = sum(len(v) for v in self.by_side.values())
        log(f"voices: {n} reference clip(s) ({', '.join(f'{k} {len(v)}' for k, v in self.by_side.items()) or 'none - add WAVs to voices/GER and voices/SOV'})")

    def for_soldier(self, soldier: dict) -> str | None:
        side = soldier.get("faction") or "ANY"
        names = self.by_side.get(side) or self.by_side.get("ANY")
        if not names:
            return None
        sid = int(soldier.get("id") or 0)
        return names[(sid * 2654435761) % (2 ** 32) % len(names)]


# ---- the words -----------------------------------------------------------------------------------------

SIDE_NOTE = {
    "GER": "a German soldier of the Wehrmacht",
    "SOV": "a Soviet soldier of the Red Army",
}
RANKS = {"PVT": "Private", "CPL": "Corporal", "SGT": "Sergeant", "SSG": "Staff Sergeant", "LT": "Lieutenant"}


def llm_chat(messages: list[dict], max_tokens: int) -> str:
    body = {"messages": messages, "max_tokens": max_tokens, "temperature": 0.8, "stream": False}
    res = http_json(CFG["llm"] + "/v1/chat/completions", body, timeout=CFG["llm_timeout"])
    text = res["choices"][0]["message"]["content"]
    return clean_line(text)


def clean_line(text: str) -> str:
    text = (text or "").strip()
    # (Thinking models: drop the thinking; quotes and stage directions round the line.)
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    text = text.strip().strip('"').strip()
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    text = " ".join(lines)
    for prefix in ("Reply:", "Answer:", "Radio:"):
        if text.startswith(prefix):
            text = text[len(prefix):].strip()
    return text[:400]


def talk_messages(req: dict) -> list[dict]:
    s = req.get("soldier") or {}
    rank = RANKS.get(s.get("rank") or "", s.get("rank") or "soldier")
    who = (f"You are {s.get('name', 'a soldier')}, a {rank.lower()}, {SIDE_NOTE.get(s.get('faction'), 'a soldier')}, "
           f"serving in {s.get('unit') or 'your unit'}" + (f" ({s.get('platoon')})" if s.get("platoon") else "") + ". ")
    state = (f"Your role: {s.get('role', 'rifleman')}. Your morale: {s.get('morale', 'steady')}. "
             + ("You are wounded. " if s.get("wounded") else "")
             + (f"You have lost {s.get('lost')} comrades. " if s.get("lost") else "")
             + (f"You have {s.get('kills')} kills. " if s.get("kills") else "")
             + (f"Right now your unit is {s.get('doing')}. " if s.get("doing") else ""))
    mems = req.get("memories") or []
    mem = ("What you have seen (newest first; 'your squad' is your own squad):\n- " + "\n- ".join(mems)) if mems else \
        "Nothing much has happened around you lately."
    rules = ("The player is an officer talking to you face to face, in the middle of a war. Answer as this man would: "
             "in English, in one to three short spoken sentences, plain soldier's speech, no stage directions, no "
             "quotation marks. Only speak of what you have seen or know; never invent events, names or places. "
             "If asked something you don't know, say so as he would.")
    msgs = [{"role": "system", "content": who + state + "\n" + mem + "\n\n" + rules}]
    for h in req.get("history") or []:
        if isinstance(h, dict) and h.get("you") and h.get("him"):
            msgs.append({"role": "user", "content": h["you"]})
            msgs.append({"role": "assistant", "content": h["him"]})
    msgs.append({"role": "user", "content": req.get("player_text") or ""})
    return msgs


def report_messages(req: dict) -> list[dict]:
    s = req.get("speaker") or {}
    rank = RANKS.get(s.get("rank") or "", "soldier")
    facts = req.get("facts") or []
    sys_msg = (f"You are {s.get('name', 'a radio operator')}, a {rank.lower()} and the radio operator of "
               f"{req.get('unit', 'your platoon')}, {SIDE_NOTE.get(s.get('faction'), 'a soldier')}. You are sending a short "
               "situation report over the radio to company headquarters. Use only the facts given - never add events, "
               "numbers or places. One or two short sentences in English, the way a radio operator speaks: terse, "
               "callsign first, ending with 'Over.' No quotation marks, no stage directions.")
    return [{"role": "system", "content": sys_msg},
            {"role": "user", "content": "Facts:\n- " + "\n- ".join(facts)}]


# ---- sound ------------------------------------------------------------------------------------------------

def decode_wav(data: bytes) -> tuple[array, int, int]:
    with wave.open(io.BytesIO(data), "rb") as w:
        ch, rate, width, n = w.getnchannels(), w.getframerate(), w.getsampwidth(), w.getnframes()
        frames = w.readframes(n)
    if width != 2:
        raise ValueError("only 16-bit WAV")
    pcm = array("h")
    pcm.frombytes(frames)
    if sys.byteorder == "big":
        pcm.byteswap()
    if ch == 2:  # (to mono: the bridge places it itself)
        pcm = array("h", ((pcm[i] + pcm[i + 1]) // 2 for i in range(0, len(pcm) - 1, 2)))
    return pcm, rate, 1


def encode_stereo(left: array, right: array, rate: int) -> bytes:
    out = array("h", bytes(len(left) * 4))
    out[0::2] = left
    out[1::2] = right
    if sys.byteorder == "big":
        out.byteswap()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(out.tobytes())
    return buf.getvalue()


def clamp16(v: float) -> int:
    return -32768 if v < -32768 else (32767 if v > 32767 else int(v))


def place_voice(pcm: array, rate: int, gain: float, pan: float) -> bytes:
    """Mono -> stereo with an equal-power pan (-1 left .. 1 right) and a gain."""
    a = (pan + 1) * math.pi / 4
    gl, gr = math.cos(a) * gain * 1.41, math.sin(a) * gain * 1.41
    left = array("h", (clamp16(s * gl) for s in pcm))
    right = array("h", (clamp16(s * gr) for s in pcm))
    return encode_stereo(left, right, rate)


def radio_voice(pcm: array, rate: int, gain: float = 0.9) -> bytes:
    """Over the radio: a narrow band (high-pass ~300 Hz, low-pass ~3 kHz), a little drive, static."""
    hp_a = 1 / (1 + 2 * math.pi * 300 / rate)
    lp_a = (2 * math.pi * 3000 / rate) / (1 + 2 * math.pi * 3000 / rate)
    out = array("h")
    prev_x = prev_hp = lp = 0.0
    seed = 12345
    for s in pcm:
        x = float(s)
        hp = hp_a * (prev_hp + x - prev_x)
        prev_x, prev_hp = x, hp
        lp += lp_a * (hp - lp)
        y = math.tanh(lp / 12000.0 * 1.8) * 14000.0
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        y += ((seed >> 16) % 900) - 450
        out.append(clamp16(y * gain))
    return encode_stereo(out, out, rate)


class Player:
    """Plays one voice at a time, in order (a man finishes before the next speaks)."""

    def __init__(self) -> None:
        self.q: queue.Queue = queue.Queue()
        self.t = threading.Thread(target=self.run, daemon=True)
        self.t.start()

    def add(self, wav: bytes) -> None:
        self.q.put(wav)

    def run(self) -> None:
        while True:
            wav = self.q.get()
            if winsound is None:
                vlog(f"(no sound here: {len(wav)} bytes of voice)")
                continue
            try:
                winsound.PlaySound(wav, winsound.SND_MEMORY | winsound.SND_NODEFAULT)
            except Exception as e:  # noqa: BLE001
                log(f"playback failed: {e}")


def tts(text: str, voice: str | None) -> bytes:
    body = {"text": text, "characterName": voice or "", "nonPositional": False}
    res = http_json(CFG["chasm"] + "/api/headless/v1/speech/synthesize", body, timeout=CFG["tts_timeout"])
    return base64.b64decode(res["audio"]["data"])


# ---- the bridge -------------------------------------------------------------------------------------------

class Bridge:
    def __init__(self, zomboid: Path) -> None:
        self.box = Mailbox(zomboid)
        self.voices = Voices()
        self.player = Player()
        self.llm_ok = "unknown"
        self.tts_ok = "unknown"
        self.chasm_ok = "unknown"
        self.last_probe = 0.0
        self.last_beat = 0.0
        self.pid: int | None = None
        self.stack_started = False

    def probe(self) -> None:
        try:
            http_json(CFG["chasm"] + "/health", timeout=3)
            self.chasm_ok = "ok"
        except (OSError, ValueError, urllib.error.URLError):
            self.chasm_ok = "off"
        try:
            http_json(CFG["llm"] + "/v1/models", timeout=3)
            self.llm_ok = "ok"
        except (OSError, ValueError, urllib.error.URLError):
            self.llm_ok = "off"
        if self.chasm_ok == "ok" and not self.stack_started and self.pid:
            self.stack_started = True
            try:
                http_json(CFG["chasm"] + "/api/stack/start", {}, timeout=10)
                log("asked Chasm to start its models")
            except (OSError, ValueError, urllib.error.URLError) as e:
                log(f"couldn't ask Chasm to start its models: {e}")
        if self.tts_ok == "unknown" and self.chasm_ok == "off":
            self.tts_ok = "off"

    def speak(self, text: str, voice: str | None, how: str, speaker_id: str | None) -> bool:
        if not text or self.chasm_ok != "ok":
            return False
        try:
            wav = tts(text, voice)
            pcm, rate, _ = decode_wav(wav)
        except Exception as e:  # noqa: BLE001
            self.tts_ok = "off"
            log(f"voice failed ({voice or 'default'}): {e}")
            return False
        self.tts_ok = "ok"
        if how == "radio":
            self.player.add(radio_voice(pcm, rate))
            return True
        st = self.box.state()
        gain, pan = 1.0, 0.0
        lis = st.get("listener") or {}
        spk = (st.get("speakers") or {}).get(str(speaker_id)) if speaker_id is not None else None
        if lis and spk:
            dx, dy = spk["x"] - lis["x"], spk["y"] - lis["y"]
            d = math.hypot(dx, dy)
            gain = max(CFG["min_volume"], 1 - d / CFG["hear_range"])
            # Screen right in Project Zomboid's isometric view is +x -y.
            pan = max(-1.0, min(1.0, (dx - dy) / max(1.0, d) / 1.414)) * min(1.0, d / 6)
        self.player.add(place_voice(pcm, rate, gain, pan))
        return True

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
        text, worded = fallback, "no"
        try:
            if kind == "talk":
                text = llm_chat(talk_messages(req), CFG["talk_max_tokens"]) or fallback
            elif kind == "report":
                text = llm_chat(report_messages(req), CFG["report_max_tokens"]) or fallback
            worded = "yes" if text != fallback else "no"
            self.llm_ok = "ok"
        except Exception as e:  # noqa: BLE001
            self.llm_ok = "off"
            vlog(f"language model unavailable ({e}) - using Living Front's words")
        voiced = "no"
        if kind == "talk":
            s = req.get("soldier") or {}
            voiced = "yes" if self.speak(text, self.voices.for_soldier(s), "positional", s.get("id")) else "no"
        elif kind == "report":
            s = req.get("speaker") or {}
            voiced = "yes" if self.speak(text, self.voices.for_soldier(s), "radio", None) else "no"
        self.box.answer(rid, {"status": "ok", "text": text, "worded": worded, "voiced": voiced})
        log(f"{kind} #{rid}: {'worded' if worded == 'yes' else 'plain'}, {'voiced' if voiced == 'yes' else 'text'}"
            f" ({time.time() - t0:.1f} s): {text[:90]}")

    def tick(self) -> None:
        now = time.time()
        if now - self.last_beat >= 1.0:
            self.last_beat = now
            self.pid = game_pid() if os.name == "nt" else self.pid
            if self.pid or os.name != "nt":
                write_heartbeat(self.pid)
            self.box.write_status(self.llm_ok, self.tts_ok, self.chasm_ok)
            self.box.clean()
        if now - self.last_probe >= 15:
            self.last_probe = now
            self.probe()
        for p in self.box.requests():
            self.handle(p)

    def run(self, once: bool = False) -> None:
        log(f"Living Front bridge {VERSION}: game folder {self.box.root}")
        log(f"Chasm at {CFG['chasm']}, language model at {CFG['llm']}, Chasm heartbeat in {CFG['chasm_bridge_root']}")
        self.voices.install()
        self.probe()
        log(f"Chasm {self.chasm_ok}, language model {self.llm_ok}")
        while True:
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001
                log(f"error: {e}")
            if once:
                return
            time.sleep(0.2)


def main() -> None:
    global VERBOSE
    ap = argparse.ArgumentParser(description="Living Front bridge to Chasm")
    ap.add_argument("--zomboid", default=str(Path.home() / "Zomboid"), help="the Zomboid user folder")
    ap.add_argument("--once", action="store_true", help="one pass, then exit (testing)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    VERBOSE = args.verbose
    Bridge(Path(args.zomboid)).run(once=args.once)


if __name__ == "__main__":
    main()
