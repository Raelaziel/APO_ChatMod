# APO Windrose Chat Mod

Simple UE4SS Lua chat mod for Windrose multiplayer.

## What It Does

- Adds a basic chat command path: player -> server -> all connected players.
- Supports `chat <message>` and `wrchat <message>`.
- Writes server-side chat history to `WindroseChat/chat_server.log`.
- Mirrors the newest received chat line through the game's native side notification.

## Current UI Limitation

The in-game notification mirror is intentionally single-line only.

Multiline/native stacked chat was tested through multiple native notification widgets and caused client crashes on repeated messages. The stable release therefore shows only the latest line in the HUD notification while the full server log remains available on the dedicated server.

## Release Folders

```text
client/
  WindroseChat/
    Config/
    Scripts/main.lua
    README.md

server/
  WindroseChat/
    Config/
    Scripts/main.lua
    README.md

source/
  Config/
  Scripts/main.lua
  README.md
```

## Client Install

Copy:

```text
E:\APO_ChatMod\client\WindroseChat
```

to the client UE4SS mods folder:

```text
<Windrose>\R5\Binaries\Win64\ue4ss\Mods\WindroseChat
```

Enable it in:

```text
<Windrose>\R5\Binaries\Win64\ue4ss\Mods\mods.txt
```

Add or update:

```text
WindroseChat : 1
```

## Server Install

Copy:

```text
E:\APO_ChatMod\server\WindroseChat
```

to the dedicated server UE4SS mods folder:

```text
<Windrose Dedicated Server>\R5\Binaries\Win64\ue4ss\Mods\WindroseChat
```

Enable it in:

```text
<Windrose Dedicated Server>\R5\Binaries\Win64\ue4ss\Mods\mods.txt
```

Add or update:

```text
WindroseChat : 1
```

## Usage

Open the UE4SS console and type:

```text
chat hello everyone
```

or:

```text
wrchat hello everyone
```

The server broadcasts the message to connected players.

## Logs

On the dedicated server, chat is appended to:

```text
R5\Binaries\Win64\ue4ss\Mods\WindroseChat\chat_server.log
```

Runtime files such as `chat_server.log` and `chat_overlay.txt` are not included in this release package.

## Version

Current bundled script version:

```text
0.3.10-side-single-stable
```

