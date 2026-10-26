# Living Front bridge

Connects Living Front (Project Zomboid) to [Chasm](https://github.com/chasmlol/chasm), so soldiers
answer you in their own words and voices, and radio operators send voiced reports.

The game's Lua can't make web requests or play sound files, so this helper does it. It talks to
the mod through files in `Zomboid\Lua\LivingFront\chasm\`, to Chasm's language model
(`127.0.0.1:5001`) and voices (`127.0.0.1:7341`), and plays the voices itself (placed by where
the speaker stands, or over the radio).

## Use

1. In Chasm: choose and download a language model (Settings - LLM) and select **faster-qwen3-tts**
   as the voice engine (Settings - TTS).
2. Put a few reference voice clips in `voices\GER` and `voices\SOV` (see `voices\README.md`).
3. Start `run_lf_bridge.bat` and leave its window open. Start the game.

It writes Chasm's game heartbeat while Project Zomboid runs, so Chasm starts its models for you.
In the game, the Living Front debug tools show whether the bridge is running. Without the bridge,
everything still works - soldiers and radio operators speak in Living Front's own words, as text.

Log: `lf_bridge.log` beside this file. Standard library only (Python 3.9+); `run_lf_bridge.bat`
uses Chasm's own `uv` to provide Python if needed.
