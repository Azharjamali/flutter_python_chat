# Signaling Server

A minimal WebSocket signaling server for learning WebRTC. Its only job is to
relay messages between clients so they can set up a direct
peer-to-peer video/audio call — it never touches the actual audio/video
data or chat text, and it doesn't store anything to disk.

## What is "signaling"?

Before two WebRTC apps can send video/audio directly to each other, they
need to exchange some setup information first:

- **SDP offer/answer** — "here's what audio/video formats I support"
- **ICE candidates** — "here's how you can reach me on the network"

WebRTC doesn't define *how* this exchange happens — that's up to us. This
server is the simplest possible way to do it: clients connect over a
WebSocket, register a stable device ID, join a "room" (just a string ID
shared by both sides of a chat), and any offer/answer/ICE/chat/call message
one client sends gets forwarded to the other device(s) in the same room.
Once the SDP/ICE exchange is done, audio/video flows directly peer-to-peer
and this server is no longer involved.

## Requirements

- Python 3.13.3 (or any modern Python 3)
- The `websockets` library

## Setup

```bash
cd signaling_server
python -m venv venv
venv\Scripts\activate        # Windows
pip install -r requirements.txt
```

## Run

```bash
python server.py
```

You should see:

```
Discovery listener on udp://0.0.0.0:8766
Starting signaling server on ws://0.0.0.0:8765
Waiting for clients to connect... (Ctrl+C to stop)
```

The server listens on **port 8765** (WebSocket signaling) and **port 8766**
(UDP auto-discovery). As clients connect, register, join rooms, and send
messages, you'll see log lines printed to the terminal like:

```
[CONNECT] New client connected: ('192.168.1.10', 51422)
[REGISTER] a1b2c3d4-... online
[JOIN] a1b2c3d4-... joined room 'room1' (1/2 members)
[JOIN] e5f6a7b8-... joined room 'room1' (2/2 members)
[RELAY] Forwarding 'call-invite' in room 'room1'
[RELAY] Forwarding 'offer' in room 'room1'
[RELAY] Forwarding 'ice-candidate' in room 'room1'
[RELAY] Forwarding 'answer' in room 'room1'
[DISCONNECT] a1b2c3d4-... offline
```

This is on purpose — the print statements are there so you can watch the
signaling handshake happen in real time while you learn. Note the server
never prints chat message text or call content, only routing info
(message type + room).

### Auto-discovery instead of typing an IP

The Flutter app finds this server automatically: it broadcasts a small UDP
packet on the LAN asking "who is the azharChating signaling server?", and
this server's discovery listener (port 8766) replies with its WebSocket
port. The app reads the server's IP address off the reply packet itself, so
you never need to run `ipconfig` or type an IP into the app manually. This
only works if both devices are actually on the same LAN/Wi-Fi and the
network allows UDP broadcast — some routers/hotspots with "AP isolation"
block it, in which case the app's manual-IP fallback still works exactly
like before.

## Protocol (v2)

Every message is a JSON object with a `"type"` field. The server only ever
looks at `type`, `room`, and `device_id` — it never inspects `sdp`,
`candidate`, or chat `text` contents, and it never persists anything to
disk (each phone keeps its own local chat history).

### Identity model

Unlike a simple "room = 2 sockets" server, this one separates **who** a
client is from **where** it's currently connected:

- Each app instance generates a random `device_id` once and keeps it
  forever (persisted locally on the phone).
- `register` binds the current WebSocket connection to that `device_id`.
- Room membership (`rooms`) is keyed by `device_id` and does **not**
  change when a socket disconnects/reconnects — only "is this device_id
  currently reachable" (`connected`) changes. This lets the phone's
  background connection drop and reconnect (Wi-Fi roaming, app restarts)
  without needing to "rejoin" every chat.
- If a message is addressed to a room whose other member isn't currently
  connected, it is **dropped** (logged as `[DROP]`, not queued) — this
  server has no store-and-forward and no internet push (no FCM/APNs). It
  is a LAN-only relay: both devices' apps need a live connection to this
  same server for anything to be delivered.

### Message types

| type              | direction                        | payload                                                                 | server's job                                  |
|-------------------|-----------------------------------|--------------------------------------------------------------------------|-------------------------------------------------|
| `register`        | client → server                   | `{ "type": "register", "device_id": "..." }`                             | bind this socket to a device_id                |
| `join`            | client → server                   | `{ "type": "join", "room": "room1", "device_id": "..." }`                 | add device to the room                         |
| `joined`          | server → client                   | `{ "type": "joined", "room": "room1", "member_count": 1 }`                | tell client it joined + how many members       |
| `leave`           | client → server                   | `{ "type": "leave", "room": "room1", "device_id": "..." }`                | remove device from the room                    |
| `room-full`       | server → client                   | `{ "type": "room-full", "room": "room1" }`                                | sent if a room already has 2 *different* devices |
| `peer-status`     | server → other client(s)          | `{ "type": "peer-status", "room": "room1", "device_id": "...", "status": "online"\|"offline" }` | notify room members when a device connects/disconnects |
| `chat`            | client → server → other client(s) | `{ "type": "chat", "room": "room1", "device_id": "...", "msg_id": "...", "text": "...", "ts": 0 }` | relay unchanged, never stored |
| `call-invite`     | client → server → other client(s) | `{ "type": "call-invite", "room": "room1", "device_id": "...", "call_type": "audio"\|"video" }` | relay unchanged — this is the "ring" signal |
| `call-accept`     | client → server → other client(s) | `{ "type": "call-accept", "room": "room1", "device_id": "..." }`          | relay unchanged — caller may now send an SDP offer |
| `call-decline`    | client → server → other client(s) | `{ "type": "call-decline", "room": "room1", "device_id": "..." }`         | relay unchanged                                |
| `call-cancel`     | client → server → other client(s) | `{ "type": "call-cancel", "room": "room1", "device_id": "..." }`          | relay unchanged — caller gave up before an answer |
| `call-end`        | client → server → other client(s) | `{ "type": "call-end", "room": "room1", "device_id": "..." }`             | relay unchanged                                |
| `offer`           | client → server → other client(s) | `{ "type": "offer", "room": "room1", "device_id": "...", "sdp": {...} }`  | relay unchanged                                |
| `answer`          | client → server → other client(s) | `{ "type": "answer", "room": "room1", "device_id": "...", "sdp": {...} }` | relay unchanged                                |
| `ice-candidate`   | client → server → other client(s) | `{ "type": "ice-candidate", "room": "room1", "device_id": "...", "candidate": {...} }` | relay unchanged             |

### Discovery (UDP, separate from the WebSocket protocol above)

| type              | direction        | payload                                                              |
|-------------------|------------------|-------------------------------------------------------------------------|
| `discover`        | client → server (UDP broadcast, port 8766) | `{ "type": "discover", "app": "azharChating", "proto": 1 }` |
| `discover-reply`  | server → client (UDP unicast)              | `{ "type": "discover-reply", "ws_port": 8765, "server_name": "..." }` |

A room holds at most **2** distinct `device_id`s (this is a 1-to-1 call
practice project).

**Call flow (once both devices are in the same room):**
1. Caller sends `call-invite` (with `call_type`) → callee's app rings.
2. Callee sends `call-accept` (or `call-decline`/the caller sends
   `call-cancel` if they give up first).
3. Only after `call-accept`: caller creates the SDP **offer** and sends it.
4. Callee receives the `offer`, creates an **answer**, sends it back.
5. Both sides send `ice-candidate` messages as they discover them
   (can happen throughout/after steps 3-4).
6. Once ICE lets the two peers find a direct network path, audio/video
   flow **directly between the two apps** — no longer through this server.
7. Either side sends `call-end` when hanging up.
