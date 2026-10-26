# Living Front bridge (text)

Lets you talk to Living Front's soldiers in your own words: each man answers in character, from
the life the mod gave him (home, trade, family, temperament, how he talks), what he has seen, and
what you have said to him before. Radio operators word their own reports.

Project Zomboid's Lua can't make web requests, so this helper does it. It runs a local language
model (llama.cpp's `llama-server`) while the game is running and passes text between it and the
mod through files in `Zomboid\Lua\LivingFront\chasm\`. No Chasm, no voices, no internet.

## Use

Start `run_lf_bridge.bat` and leave its window open, then play. In game, right-click a soldier,
**Talk to ...**, type and press Enter. The Living Front debug tools show whether the bridge and
the language model are ready (the model takes a little while to load the first time).

## The model

By default it uses `llama-server.exe` and the `.gguf` model Chasm downloaded. To use others, put
`llama-server.exe` (with its DLLs) in a `llama` folder here and a `.gguf` in a `models` folder,
or name them in `lf_bridge.json`:

```json
{ "llama_server": "C:/path/to/llama-server.exe", "model": "C:/path/to/model.gguf",
  "gpu_layers": 999, "ctx": 8192 }
```

If the game stutters while the model is loaded, lower `gpu_layers` (0 runs it on the processor:
slower replies, no load on the graphics card). Logs: `lf_bridge.log`, `llama_server.log`.
