
Production package for the Windrose chat mod.
!! THIS MOD WAS TESTED ON LOCAL MACHINE WITH NO MORE THEN 2 OTHER PLAYERS !!

This build is the **server-side UE4SS transport** version:

- players do **not** need client-side UE4SS
- the client runs only `WindroseChatOverlay.exe`
- the dedicated server runs one UE4SS C++ mod: `WindroseChatServerCpp`
- chat transport is HTTP:
  - client overlay -> server UE4SS C++ endpoint
  - server endpoint -> client overlay feed

## Folder Layout

- `client`
  Ready-to-copy files for the normal game client.
- `dedicated-server`
  Ready-to-copy files for the dedicated server with UE4SS installed.
- `source`
  Source snapshot for the overlay, legacy client UE4SS bridge, Lua transport, and new server UE4SS C++ endpoint.

## Client Install

Copy:

```text
...\client\R5\Binaries\Win64\...
```

into:

```text
...\SteamLibrary\steamapps\common\Windrose\R5\Binaries\Win64\...
```

Required client files:

- `WindroseChatOverlay.exe`
- `WRChat_Client.ini`

Client UE4SS is not required in this build.

Edit:

```text
R5\Binaries\Win64\WRChat_Client.ini
```

For local testing on the same machine:

```ini
[Client]
ServerUrl=http://127.0.0.1:8765
```

For LAN/public server:

```ini
[Client]
ServerUrl=http://SERVER_IP_OR_DNS:8765
; PlayerName=OptionalDisplayName
```

If `PlayerName` is empty, the overlay tries to resolve the active Windrose identity locally from save data and logs.

## Dedicated Server Install

This requires UE4SS installed on the dedicated server.

Copy:

```text
...\dedicated-server\R5\Binaries\Win64\...
```

into:

```text
...\SteamLibrary\steamapps\common\Windrose Dedicated Server\R5\Binaries\Win64\...
```

Required server files:

- `ue4ss/Mods/WindroseChatServerCpp/dlls/main.dll`
- `ue4ss/Mods/WindroseChatServerCpp/WRChat_Server.ini`

Then merge:

```text
dedicated-server\R5\Binaries\Win64\ue4ss\Mods\mods.txt.append.txt
```

into the server `mods.txt`.

Required server entry:

```text
WindroseChatServerCpp : 1
```

Server config:

```ini
[Server]
Port=8765
MaxMessages=200
```

The server endpoint listens on all interfaces:

```text
http://0.0.0.0:8765
```

Open that port in firewall/router if clients connect from another machine.

## Controls

Client overlay controls:

- `Enter`
  Open chat input.
- `Enter` again
  Send the current message.
- `Esc`
  Cancel input.
- `Shift` / `CapsLock`
  Uppercase letters while typing.
- `Mouse wheel`
  Scroll chat history while input is open. The input view renders up to the last 10 chat lines at once.
- `PageUp` / `PageDown`
  Scroll chat history while input is open.
- `Up` / `Down`
  Step through older or newer chat lines while input is open.
- `Home` / `End`
  Jump to older or newest chat lines.

## Server API

The UE4SS C++ server mod exposes:

```text
GET /health
GET /v1/chat/feed?since=<lastId>&accountId=<id>&sessionId=<session>
GET /v1/chat/send?speaker=<name>&message=<text>&accountId=<id>&sessionId=<session>
```

The feed format is plain text:

```text
id<TAB>unixTimestamp<TAB>speaker<TAB>message
```

## Current Limitations

- The server now validates the active `AccountId + BLPlayerSessionId` pair from the live game session before accepting chat traffic.
- This is session-bound verification, not a standalone public auth service.
- If your hosting only allows `Content\Paks\~mods` and does not support UE4SS or extra executables, this server-side endpoint cannot run there.

## Logs

Client log:

```text
R5/Binaries/Win64/WindroseChatOverlayExternal.log
```

Server logs:

```text
R5/Binaries/Win64/ue4ss/Mods/WindroseChatServerCpp/dlls/WindroseChatServerCpp.log
R5/Binaries/Win64/ue4ss/Mods/WindroseChatServerCpp/WindroseChatServer.log
```
