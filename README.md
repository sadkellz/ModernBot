# ModernBot

SF6 bot that reads live game state and injects inputs to automate fighting and menus. Runs as a REFramework Lua script.

## Setup

1. Install [REFramework](https://github.com/praydog/REFramework) for SF6
2. Copy `modern_bot/` into your REFramework `reframework/autorun/` folder
3. Launch the game -- the bot UI appears in the REFramework menu

> [!CAUTION]
> REFramework automatically disables scripts when entering any online mode.

## Features

- **Pulse Input** -- press a button at random intervals with configurable hold/release timing. Optional Auto button co-press.
- **Hold Input** -- continuously hold a button and/or forward/back direction.
- **Charge Move** -- hold down-back, wait for the game's charge state, then jump + attack. Reads `charge_frame` directly from the engine.
- **Wakeup Super** -- on getup, mash SA1/SA2/SA3 (configurable per-level toggles and % chance). Human-like input timing.
- **Auto Rematch** -- automatically rematch, return to lobby if declined, skip intros/win poses.
- **Side Detection** -- auto-detects P1/P2 side in online and training mode.
- **Win/Loss Tracking** -- per-round and per-match stats shown in an always-visible overlay.

## Config

Settings are saved to `modern_bot_cfg.json` via the Save button. Automatically loads on first run/reset or can me loaded via the Load button.
