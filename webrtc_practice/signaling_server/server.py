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
    "joined"        - {room, member_count}
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
import socket

import websockets

# --- Configuration ---------------------------------------------------------

HOST = "0.0.0.0"          # listen on all network interfaces (so phones on WiFi can connect)
PORT = 8765                # port the WebSocket server listens on
DISCOVERY_PORT = 8766      # port the UDP auto-discovery listener listens on
MAX_CLIENTS_PER_ROOM = 2   # this is a 1-to-1 call app, so only 2 devices per room

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


def rooms_of(device_id: str) -> list[str]:
    """Every room `device_id` currently belongs to."""
    return [room_id for room_id, members in rooms.items() if device_id in members]


async def send_to_client(websocket, message: dict) -> None:
    """Send a JSON message to a single client, ignoring errors if it already
    disconnected (this can happen in normal use, e.g. a race between the
    peer hanging up and us trying to relay one last message to them)."""
    try:
        await websocket.send(json.dumps(message))
    except websockets.ConnectionClosed:
        pass


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


async def handle_register(websocket, device_id: str) -> None:
    """Bind `websocket` to `device_id`. If that device_id already had a
    (presumably stale) socket registered, this one replaces it - a phone
    reconnecting after a network blip doesn't need to do anything special.
    """
    connected[device_id] = websocket
    device_of[websocket] = device_id
    print(f"[REGISTER] {device_id} online")

    for room_id in rooms_of(device_id):
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
                device_id = message.get("device_id")
                if device_id:
                    await handle_register(websocket, device_id)
                else:
                    print("[ERROR] 'register' message missing 'device_id' field")
                continue

            # Every message type below this point requires the socket to
            # have already registered a device_id.
            sender_device_id = device_of.get(websocket)
            if sender_device_id is None:
                print(f"[ERROR] Got '{message_type}' from an unregistered socket")
                continue

            if message_type == "join":
                room_id = message.get("room")
                if room_id:
                    await handle_join(websocket, sender_device_id, room_id)
                else:
                    print("[ERROR] 'join' message missing 'room' field")

            elif message_type == "leave":
                room_id = message.get("room")
                if room_id:
                    await handle_leave(sender_device_id, room_id)

            elif message_type in (
                "chat",
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

class DiscoveryProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        try:
            message = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return

        if message.get("type") == "discover":
            reply = json.dumps({
                "type": "discover-reply",
                "ws_port": PORT,
                "server_name": socket.gethostname(),
            })
            self.transport.sendto(reply.encode("utf-8"), addr)
            print(f"[DISCOVERY] Replied to {addr}")


async def main() -> None:
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
