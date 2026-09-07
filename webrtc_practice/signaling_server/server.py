"""
WebRTC Signaling Server (learning project) - v2
==================================================

WHAT IS A "SIGNALING SERVER" AND WHY DO WE NEED ONE?
------------------------------------------------------
Two WebRTC apps that want to video-call each other need to agree on some
information before they can connect directly (peer-to-peer):
    - "Here's the kind of audio/video I can send" (SDP offer/answer)
    - "Here's how you can reach me over the network" (ICE candidates)

WebRTC itself does NOT define how this information gets exchanged - that's
up to us. This server's only job is to be a simple messenger: it receives
a message from one client and forwards it to the other client in the same
"room". It never looks at, understands, or modifies the actual contents of
an offer/answer/ice-candidate/chat message - it just passes the JSON through.

Once the two apps have exchanged this info, the actual audio/video data
flows directly between them (peer-to-peer) and this server is no longer
involved at all.

WHAT'S NEW IN v2
------------------
The original version identified a "peer" by its WebSocket connection: if
the socket closed, the peer was gone. That's fine for a single foreground
call screen, but the Flutter app now keeps a connection alive in the
background (an Android foreground service) so it can receive chat
messages and incoming-call notifications even when no chat/call screen is
open. A background connection can drop and reconnect many times (Wi-Fi
roaming, doze mode, app restarts) without the user ever "leaving" a chat.

So v2 separates two ideas that used to be the same thing:
    - "device_id": a stable ID the app generates once and keeps forever
      (persisted locally). This is WHO you are.
    - "websocket connection": WHERE you currently are. Comes and goes.

A room is now a set of device_ids (persists across reconnects), and the
server separately tracks which device_ids currently have a live socket.
Relaying a message looks up "is the other member of this room currently
connected?" - if not, the message is simply dropped (logged, not queued).
This server still has no database and no internet-scale push notification
system (no FCM/APNs) - it is a LAN-only relay, same as before, just with a
sturdier notion of identity.

HOW THE PROTOCOL WORKS
------------------------
Every message sent over the WebSocket is a JSON object with a "type" field.

    "register"      - {device_id} - bind this socket to a device_id. Must be
                       the first message sent after connecting.
    "open-chat"     - {peer_id} - open a 1:1 chat with another unique user id
    "join"          - {room, device_id} - add device_id to a room
    "leave"         - {room, device_id} - remove device_id from a room
    "chat"          - {room, device_id, msg_id, text, ts} - relayed as-is
    "call-invite"   - {room, device_id, call_type} - "ring" the other side
    "call-accept"   - {room, device_id} - callee accepted, proceed to SDP
    "call-decline"  - {room, device_id} - callee declined
    "call-cancel"   - {room, device_id} - caller gave up before an answer
    "call-end"      - {room, device_id} - either side ended an active call
    "offer"         - SDP offer, relayed as-is (only sent after call-accept)
    "answer"        - SDP answer, relayed as-is
    "ice-candidate" - ICE candidate, relayed as-is

Server -> client only:
    "registered"    - {device_id}
    "joined"        - {room, member_count, peer_id, peer_online}
    "chat-opened"   - {room, peer_id, peer_online} - someone started a chat with you
    "room-full"     - {room}
    "peer-status"   - {room, device_id, status: "online"|"offline"}

Each room holds at most 2 device_ids (this is a 1-to-1 call practice project).

A second, separate listener answers LAN auto-discovery broadcasts over UDP
(see DISCOVERY_PORT below) so the Flutter app doesn't need the user to type
this machine's IP address.

Run this file with:
    python server.py
"""

import asyncio
import json
import os
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional
from urllib.parse import urlparse

import websockets

# --- Configuration ---------------------------------------------------------

HOST = "0.0.0.0"          # listen on all network interfaces (so phones on WiFi can connect)
PORT = 8765                # port the WebSocket server listens on
DISCOVERY_PORT = 8766      # port the UDP auto-discovery listener listens on
HTTP_PORT = 8767           # status image/video upload and download
MAX_CLIENTS_PER_ROOM = 2   # this is a 1-to-1 call app, so only 2 devices per room
STATUS_TTL_MS = 24 * 60 * 60 * 1000
SAFE_MEDIA_NAME = re.compile(r"^[a-zA-Z0-9._-]+$")
_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MEDIA_DIR = os.path.join(_BASE_DIR, "status_media")
STATUSES_FILE = os.path.join(_BASE_DIR, "statuses.json")

# --- Server state ------------------------------------------------------------
#
# We keep everything in plain Python dictionaries, in memory. There's no
# database - if you restart the server, all rooms/registrations/chat history
# are forgotten (chat history itself is never stored here at all - each
# phone keeps its own local copy, see the Flutter app's sqlite database).
#
# `connected` maps a device_id -> the websocket it's currently reachable on
#   (only present while that device has a live connection).
# `rooms` maps a room ID -> the set of device_ids that are members of it.
#   This does NOT change when a device disconnects/reconnects - only
#   `connected` changes. A room's membership is "sticky".
# `device_of` maps a websocket -> the device_id that registered it, so that
#   when a socket disconnects we know whose entry to clear from `connected`
#   without them having to tell us again.

connected: dict[str, object] = {}
rooms: dict[str, set[str]] = {}
device_of: dict[object, str] = {}
claimed_usernames: set = set()
USERNAMES_FILE = os.path.join(_BASE_DIR, "usernames.json")
statuses: dict = {}


def load_claimed_usernames() -> None:
    global claimed_usernames
    try:
        with open(USERNAMES_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, list):
            claimed_usernames = {str(name).strip().lower() for name in data if name}
    except (OSError, json.JSONDecodeError):
        claimed_usernames = set()


def save_claimed_usernames() -> None:
    with open(USERNAMES_FILE, "w", encoding="utf-8") as handle:
        json.dump(sorted(claimed_usernames), handle)


def normalize_username(value: str) -> str:
    return (value or "").strip().lower()


USERNAME_RE = re.compile(r"^[a-z0-9_]{3,20}$")


def now_ms() -> int:
    return int(time.time() * 1000)


def load_statuses() -> None:
    global statuses
    try:
        with open(STATUSES_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            statuses = data
        elif isinstance(data, list):
            statuses = {item["id"]: item for item in data if isinstance(item, dict) and item.get("id")}
    except (OSError, json.JSONDecodeError):
        statuses = {}
    prune_statuses()


def save_statuses() -> None:
    with open(STATUSES_FILE, "w", encoding="utf-8") as handle:
        json.dump(statuses, handle)


def prune_statuses() -> None:
    cutoff = now_ms() - STATUS_TTL_MS
    expired = [sid for sid, item in statuses.items() if int(item.get("ts") or 0) < cutoff]
    for sid in expired:
        item = statuses.pop(sid, None) or {}
        media_url = item.get("media_url") or ""
        name = os.path.basename(media_url)
        path = os.path.join(MEDIA_DIR, name)
        if name and SAFE_MEDIA_NAME.match(name) and os.path.isfile(path):
            try:
                os.remove(path)
            except OSError:
                pass
    if expired:
        save_statuses()


def public_status(item: dict, include_views: bool = False) -> dict:
    data = {
        "type": "status-new",
        "id": item.get("id"),
        "author": item.get("author"),
        "kind": item.get("kind") or "text",
        "text": item.get("text") or "",
        "bg": item.get("bg") or 0xFF075E54,
        "media_url": item.get("media_url") or "",
        "ts": item.get("ts"),
    }
    if include_views:
        data["views"] = item.get("views") or []
    return data


async def broadcast_all(message: dict, exclude: Optional[str] = None) -> None:
    for device_id, websocket in list(connected.items()):
        if device_id == exclude:
            continue
        await send_to_client(websocket, message)


class StatusMediaHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[HTTP]", fmt % args)

    def do_PUT(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/status-media/"):
            self.send_error(404)
            return
        name = os.path.basename(parsed.path)
        if not SAFE_MEDIA_NAME.match(name):
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > 50_000_000:
            self.send_error(413)
            return
        os.makedirs(MEDIA_DIR, exist_ok=True)
        dest = os.path.join(MEDIA_DIR, name)
        remaining = length
        with open(dest, "wb") as handle:
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                handle.write(chunk)
                remaining -= len(chunk)
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"url": f"/status-media/{name}"}).encode())

    def do_GET(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/status-media/"):
            self.send_error(404)
            return
        name = os.path.basename(parsed.path)
        path = os.path.join(MEDIA_DIR, name)
        if not SAFE_MEDIA_NAME.match(name) or not os.path.isfile(path):
            self.send_error(404)
            return
        ctype = "application/octet-stream"
        if name.endswith(".jpg") or name.endswith(".jpeg"):
            ctype = "image/jpeg"
        elif name.endswith(".png"):
            ctype = "image/png"
        elif name.endswith(".mp4") or name.endswith(".mov"):
            ctype = "video/mp4"
        elif name.endswith(".webm"):
            ctype = "video/webm"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(os.path.getsize(path)))
        self.end_headers()
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)


def start_status_http() -> None:
    os.makedirs(MEDIA_DIR, exist_ok=True)
    server = ThreadingHTTPServer((HOST, HTTP_PORT), StatusMediaHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"Status media on http://{HOST}:{HTTP_PORT}")


def rooms_of(device_id: str) -> list:
    """Every room `device_id` currently belongs to."""
    return [room_id for room_id, members in rooms.items() if device_id in members]


def dm_room(user_a: str, user_b: str) -> str:
    """Stable 1:1 room id so both phones always land in the same chat."""
    first, second = sorted([user_a, user_b])
    return f"dm:{first}:{second}"


def other_member(room_id: str, device_id: str) -> Optional[str]:
    members = rooms.get(room_id, set())
    others = [member for member in members if member != device_id]
    return others[0] if others else None


async def send_to_client(websocket, message: dict) -> None:
    """Send a JSON message to a single client, ignoring errors if it already
    disconnected (this can happen in normal use, e.g. a race between the
    peer hanging up and us trying to relay one last message to them)."""
    try:
        await websocket.send(json.dumps(message))
    except websockets.ConnectionClosed:
        pass


async def send_to_device(device_id: str, message: dict) -> bool:
    target_ws = connected.get(device_id)
    if target_ws is None:
        return False
    await send_to_client(target_ws, message)
    return True


async def deliver_to_peer(sender_id: str, message: dict, peer_id: str = "") -> None:
    """Send `message` to a specific peer, or to every other member of the
    sender's rooms if no peer is given. Used for typing so it still works
    when the in-memory room was lost after a server restart.
    """
    targets = set()
    peer_id = normalize_username(peer_id)
    if peer_id and peer_id != sender_id:
        targets.add(peer_id)
    room_id = message.get("room")
    if room_id:
        for member in rooms.get(room_id, set()):
            if member != sender_id:
                targets.add(member)
    if not targets:
        for room in rooms_of(sender_id):
            other = other_member(room, sender_id)
            if other:
                targets.add(other)
    for target in targets:
        await send_to_device(target, message)


async def relay_to_room(sender_device_id: str, room_id: str, message: dict) -> None:
    """Forward `message` to every OTHER device_id in `room_id` that is
    currently connected (not the sender). If a member isn't currently
    connected, the message is simply dropped - this server does not queue
    or store undelivered messages.

    This is the core of the signaling server: it does not read or change
    `message` in any way, it just passes it along to whoever else is in
    the room and currently reachable.
    """
    for member_id in rooms.get(room_id, set()):
        if member_id == sender_device_id:
            continue
        target_ws = connected.get(member_id)
        if target_ws is not None:
            await send_to_client(target_ws, message)
        else:
            print(f"[DROP] '{message.get('type')}' for offline device {member_id} in room '{room_id}'")


async def handle_register(websocket, device_id: str, returning: bool = False) -> None:
    """Bind this socket to a unique username.

    A name already claimed by someone else is rejected. Coming back with
    your own saved username is allowed only while that name is offline.
    """
    device_id = normalize_username(device_id)
    if not USERNAME_RE.match(device_id):
        await send_to_client(websocket, {
            "type": "error",
            "message": "Username must be 3-20 letters, numbers, or underscores",
        })
        return

    existing_ws = connected.get(device_id)
    if existing_ws is not None and existing_ws is not websocket:
        print(f"[TAKEN] Username '{device_id}' is already online")
        await send_to_client(websocket, {
            "type": "username-taken",
            "device_id": device_id,
        })
        return

    if device_id in claimed_usernames and not returning:
        print(f"[TAKEN] Username '{device_id}' is already claimed")
        await send_to_client(websocket, {
            "type": "username-taken",
            "device_id": device_id,
        })
        return

    if device_id not in claimed_usernames:
        claimed_usernames.add(device_id)
        save_claimed_usernames()

    connected[device_id] = websocket
    device_of[websocket] = device_id
    print(f"[REGISTER] {device_id} online")

    await send_to_client(websocket, {
        "type": "registered",
        "device_id": device_id,
    })
    prune_statuses()
    await send_to_client(websocket, {
        "type": "status-list",
        "items": [
            public_status(item, include_views=item.get("author") == device_id)
            for item in statuses.values()
        ],
    })

    for room_id in rooms_of(device_id):
        peer_id = other_member(room_id, device_id)
        if peer_id:
            await send_to_client(websocket, {
                "type": "chat-opened",
                "room": room_id,
                "peer_id": peer_id,
                "peer_online": peer_id in connected,
            })
        await relay_to_room(device_id, room_id, {
            "type": "peer-status",
            "room": room_id,
            "device_id": device_id,
            "status": "online",
        })


async def handle_join(websocket, device_id: str, room_id: str) -> None:
    """Add `device_id` to the room with ID `room_id`."""

    members = rooms.setdefault(room_id, set())

    if device_id not in members and len(members) >= MAX_CLIENTS_PER_ROOM:
        print(f"[REJECTED] Room '{room_id}' is full, rejecting device {device_id}")
        await send_to_client(websocket, {"type": "room-full", "room": room_id})
        return

    members.add(device_id)
    print(f"[JOIN] {device_id} joined room '{room_id}' ({len(members)}/{MAX_CLIENTS_PER_ROOM} members)")

    await send_to_client(websocket, {
        "type": "joined",
        "room": room_id,
        "member_count": len(members),
    })

    # Existing members need to know someone just joined so they can
    # start the WebRTC offer/answer handshake.
    await relay_to_room(device_id, room_id, {
        "type": "peer-status",
        "room": room_id,
        "device_id": device_id,
        "status": "online",
    })


async def handle_open_chat(websocket, device_id: str, peer_id: str) -> None:
    """Open (or resume) a 1:1 chat between two unique user ids."""
    peer_id = peer_id.strip()
    if not peer_id or peer_id == device_id:
        await send_to_client(websocket, {
            "type": "error",
            "message": "Enter another user's username",
        })
        return

    room_id = dm_room(device_id, peer_id)
    rooms[room_id] = {device_id, peer_id}
    peer_online = peer_id in connected
    print(f"[CHAT] {device_id} opened chat with {peer_id} ({'online' if peer_online else 'offline'})")

    await send_to_client(websocket, {
        "type": "joined",
        "room": room_id,
        "peer_id": peer_id,
        "peer_online": peer_online,
        "member_count": 2 if peer_online else 1,
    })

    peer_ws = connected.get(peer_id)
    if peer_ws is not None:
        await send_to_client(peer_ws, {
            "type": "chat-opened",
            "room": room_id,
            "peer_id": device_id,
            "peer_online": True,
        })
        await send_to_client(peer_ws, {
            "type": "peer-status",
            "room": room_id,
            "device_id": device_id,
            "status": "online",
        })


async def handle_status_post(sender_id: str, message: dict) -> None:
    prune_statuses()
    kind = message.get("kind") or "text"
    if kind not in ("text", "image", "video"):
        kind = "text"
    item = {
        "id": message.get("id") or f"{sender_id}-{now_ms()}",
        "author": sender_id,
        "kind": kind,
        "text": (message.get("text") or "")[:500],
        "bg": message.get("bg") or 0xFF075E54,
        "media_url": message.get("media_url") or "",
        "ts": message.get("ts") or now_ms(),
        "views": [],
    }
    statuses[item["id"]] = item
    try:
        save_statuses()
    except OSError as exc:
        print(f"[STATUS] Could not persist status: {exc}")
    print(f"[STATUS] {sender_id} posted {kind} {item['id']} to {len(connected)} clients")
    await broadcast_all(public_status(item))


async def handle_status_delete(sender_id: str, status_id: str) -> None:
    item = statuses.get(status_id)
    if item is None or item.get("author") != sender_id:
        return
    statuses.pop(status_id, None)
    media_url = item.get("media_url") or ""
    name = os.path.basename(media_url)
    path = os.path.join(MEDIA_DIR, name)
    if name and SAFE_MEDIA_NAME.match(name) and os.path.isfile(path):
        try:
            os.remove(path)
        except OSError:
            pass
    save_statuses()
    await broadcast_all({"type": "status-delete", "id": status_id})


async def handle_status_view(viewer_id: str, status_id: str) -> None:
    item = statuses.get(status_id)
    if item is None or item.get("author") == viewer_id:
        return
    views = item.setdefault("views", [])
    if any(entry.get("viewer") == viewer_id for entry in views):
        return
    views.append({"viewer": viewer_id, "ts": now_ms()})
    save_statuses()
    author_ws = connected.get(item.get("author"))
    if author_ws is not None:
        await send_to_client(author_ws, {
            "type": "status-viewed",
            "id": status_id,
            "viewer": viewer_id,
            "views": views,
        })
        print(f"[STATUS] {viewer_id} viewed {status_id}")


async def handle_leave(device_id: str, room_id: str) -> None:
    """Explicitly remove `device_id` from a room's membership. Unlike v1,
    this is NOT triggered by a socket disconnecting - only by the app
    actually asking to leave a chat/room."""

    members = rooms.get(room_id)
    if not members or device_id not in members:
        return

    members.discard(device_id)
    print(f"[LEAVE] {device_id} left room '{room_id}' ({len(members)}/{MAX_CLIENTS_PER_ROOM} members)")

    if not members:
        del rooms[room_id]
    else:
        await relay_to_room(device_id, room_id, {
            "type": "peer-status",
            "room": room_id,
            "device_id": device_id,
            "status": "offline",
        })


async def handle_socket_close(websocket) -> None:
    """Clean up when a socket disconnects (app backgrounded/killed, network
    dropped, etc). Note this only clears `connected` (reachability) - room
    *membership* in `rooms` is untouched, so reconnecting later doesn't
    require rejoining."""

    device_id = device_of.pop(websocket, None)
    if device_id is None:
        return

    # Only clear `connected` if this socket is still the current one for
    # that device_id (it might not be, if the device already reconnected
    # on a new socket before this old one finished closing).
    if connected.get(device_id) is websocket:
        del connected[device_id]
        print(f"[DISCONNECT] {device_id} offline")

        for room_id in rooms_of(device_id):
            await relay_to_room(device_id, room_id, {
                "type": "peer-status",
                "room": room_id,
                "device_id": device_id,
                "status": "offline",
            })


async def handle_connection(websocket) -> None:
    """This function runs once for each client that connects, and keeps
    running for as long as that client stays connected. `websockets` calls
    this automatically for every new connection.
    """

    client_address = websocket.remote_address
    print(f"[CONNECT] New client connected: {client_address}")

    try:
        # This loop waits here until the client sends a message, handles
        # it, then waits for the next one - for the entire lifetime of the
        # connection.
        async for raw_message in websocket:
            try:
                message = json.loads(raw_message)
            except json.JSONDecodeError:
                print(f"[ERROR] Could not parse message as JSON: {raw_message!r}")
                continue

            message_type = message.get("type")

            if message_type == "register":
                device_id = message.get("device_id") or message.get("username")
                if device_id:
                    await handle_register(
                        websocket,
                        device_id,
                        returning=bool(message.get("returning")),
                    )
                else:
                    print("[ERROR] 'register' message missing 'device_id' field")
                continue

            # Every message type below this point requires the socket to
            # have already registered a device_id.
            sender_device_id = device_of.get(websocket)
            if sender_device_id is None:
                print(f"[ERROR] Got '{message_type}' from an unregistered socket")
                continue

            if message_type == "open-chat":
                peer_id = normalize_username(message.get("peer_id") or "")
                if peer_id:
                    await handle_open_chat(websocket, sender_device_id, peer_id)
                else:
                    print("[ERROR] 'open-chat' message missing 'peer_id' field")

            elif message_type == "join":
                room_id = message.get("room")
                if room_id:
                    await handle_join(websocket, sender_device_id, room_id)
                else:
                    print("[ERROR] 'join' message missing 'room' field")

            elif message_type == "leave":
                room_id = message.get("room")
                if room_id:
                    await handle_leave(sender_device_id, room_id)

            elif message_type == "status-post":
                await handle_status_post(sender_device_id, message)

            elif message_type == "status-delete":
                status_id = message.get("id")
                if status_id:
                    await handle_status_delete(sender_device_id, status_id)

            elif message_type == "status-view":
                status_id = message.get("id")
                if status_id:
                    await handle_status_view(sender_device_id, status_id)

            elif message_type == "status-request":
                prune_statuses()
                await send_to_client(websocket, {
                    "type": "status-list",
                    "items": [
                        public_status(item, include_views=item.get("author") == sender_device_id)
                        for item in statuses.values()
                    ],
                })

            elif message_type == "typing":
                message["device_id"] = sender_device_id
                await deliver_to_peer(
                    sender_device_id,
                    message,
                    peer_id=message.get("peer_id") or "",
                )

            elif message_type in (
                "chat",
                "chat-delivered",
                "chat-read",
                "call-invite",
                "call-accept",
                "call-decline",
                "call-cancel",
                "call-end",
                "offer",
                "answer",
                "ice-candidate",
            ):
                # This is the heart of the "signaling" job: just forward the
                # message to whoever else is in the same room, unchanged.
                # We deliberately do NOT inspect the message's payload
                # fields (sdp/candidate/text/...) - the server doesn't need
                # to understand WebRTC or chat content, only relay messages.
                room_id = message.get("room")
                if room_id:
                    print(f"[RELAY] Forwarding '{message_type}' in room '{room_id}'")
                    await relay_to_room(sender_device_id, room_id, message)
                else:
                    print(f"[ERROR] '{message_type}' message missing 'room' field")

            else:
                print(f"[WARN] Unknown message type: {message_type!r}")

    except websockets.ConnectionClosed:
        # This is the normal way a connection ends (app closed, network
        # dropped, etc) - nothing has gone wrong.
        pass

    finally:
        await handle_socket_close(websocket)
        print(f"[DISCONNECT] Client disconnected: {client_address}")


# --- LAN auto-discovery (UDP) ------------------------------------------------
#
# The Flutter app doesn't want to make the user type this machine's IP
# address. Instead, it broadcasts a small UDP packet on the local network
# asking "who is the azharChating signaling server?", and this listener
# answers directly back to whoever asked. The app then reads our IP address
# off the reply packet itself (not from any field inside the JSON) - UDP
# hands us the sender's address for free, so the client can do the same
# trick in reverse to learn ours.

def lan_ipv4_addresses():
    """IPv4 addresses phones on this LAN can use to reach this machine."""
    found = []
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        found.append(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip and not ip.startswith("127."):
                found.append(ip)
    except OSError:
        pass
    unique = []
    for ip in found:
        if ip not in unique:
            unique.append(ip)
    return unique


class DiscoveryProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        try:
            message = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return

        if message.get("type") == "discover":
            hosts = lan_ipv4_addresses()
            reply = json.dumps({
                "type": "discover-reply",
                "ws_port": PORT,
                "server_name": socket.gethostname(),
                "host": hosts[0] if hosts else addr[0],
                "hosts": hosts,
            })
            self.transport.sendto(reply.encode("utf-8"), addr)
            print(f"[DISCOVERY] Replied to {addr} with hosts={hosts}")


async def main() -> None:
    load_claimed_usernames()
    load_statuses()
    start_status_http()
    loop = asyncio.get_running_loop()

    await loop.create_datagram_endpoint(
        DiscoveryProtocol,
        local_addr=(HOST, DISCOVERY_PORT),
    )
    print(f"Discovery listener on udp://{HOST}:{DISCOVERY_PORT}")

    print(f"Starting signaling server on ws://{HOST}:{PORT}")
    print("Waiting for clients to connect... (Ctrl+C to stop)")

    async with websockets.serve(handle_connection, HOST, PORT):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
