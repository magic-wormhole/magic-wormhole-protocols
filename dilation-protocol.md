# Dilation protocol

Due to the nature of its construction, the Mailbox server unsuited for the exchange of larger amounts of data.
Therefore, many applications use the Transit protocol to establish a high-bandwidth channel to use for the acutal data transfer.

Dilation builds upon this concept, but tries to make it a first-class citizen that is also easy to use.
The idea is that clients say that they want to "dilate" a Wormhole,
and the Dilation protocol will take care of the rest to establish such a high-bandwidth connection automatically.

Additionally, the protocol takes care of automatically re-establishing such a channel after a connection interruption,
including re-sending all messages that got lost.
Furthermore, it has the concept of sub-channels built in,
and will take care of the sub-channel management and data multiplexing too.

## Overview

A dilated Wormhole connection involves several moving parts.

The Mailbox on the Mailbox server remains accessible to the application.
It is additionally used by the Dilation implementation to exchange internal coordination messages.

The usual Transit connection is replaced by a Dilation connection, that is managed by the Dilation implementation.
Compared to the Transit connection, it has additional features like resilience against connection interruptions and sub-channels.

## Capability discovery

As for Transit, this is up to the application layer protocol to handle, preferably
using the `version` phase.

TODO: This section described the version exchange within the `version` phase,
however there is also some version information in one of the first Dilation
messages itself. These are more or less redundant, but which one should we take?
 ~ piegames

The Wormhole protocol has a `versions` message sent immediately after the shared PAKE key is established.
This also serves as a key-confirmation message, allowing each side to confirm that the other side knows the right key.
The body of the `versions` message is a JSON-formatted string with keys that are available for learning the abilities of the peer.
Dilation is signaled by a key named `can-dilate`, whose value is a list of strings.
Any version present in both side's lists is eligible for use.

The connection abilities are communicated similarly to Transit, in a `dilation-abilities` key.
Currently supported: `direct-tcp-v1`, `tor-tcp-v1` and `relay-v1`.
These have similar meaning as in Transit (referring to the ability to make a direct connection, a connection via Tor and a connection via the Transit Relay respectively).
See the [Transit protocol](./Transit.md) for more details.

For example:

```
{
    "can-dilate": ["1"]
    "dilation-abilities": [
        {"type": "direct-tcp-v1"},
        {"type": "relay-v1"},
    ]
}
```

When considering the `"can-dilate"` list, implementations take the intersection (of both peers) and SHOULD select the "best" version in that intersection.
The *order* of versions in the list indicates their priority (they may not all be strings that convert to integers).
The version selected is communicated in the `please` message with `"use-version"` key.
Both sides MUST use the version selected by the Leader (see next section).

Currently there is only one version: `"1"`.

## Leaders and Followers

The Dilation protocol calls one side of the communication "Leader" and the other one "Follower".
This is an implementation detail of the protocol which should not be exposed to the upper layer application.
It is used whenever some operation should only be performed by one of the two peers.

Each side of a Wormhole has a randomly-generated dilation `side` string
(this is included in the `please` message, and is independent of the Wormhole's mailbox "side").
When the wormhole is dilated, the side with the lexicographically-higher "side" value is named the "Leader",
and the other side is named the "Follower".
The general wormhole protocol treats both sides identically, but the distinction matters for the dilation protocol.

## Mailbox changes

TODO maybe move to ./client-protocol.md? ~piegames

The Mailbox on the rendezvous server is used to deliver dilation requests and connection hints.
The current mailbox protocol uses named "phases" to distinguish messages
(rather than behaving like a regular ordered channel of arbitrary frames or bytes),
and all-number phase names are reserved for application data.
Therefore the dilation control messages use phases named `DILATE-0`, `DILATE-`, etc.
Like for the "regular" named phases, each side maintains its own counter,
so one side might be up to e.g. `DILATE-5` while the other has only gotten as far as `DILATE-2`.
Remember that all phases beyond the initial `pake` phase are encrypted by the shared session key.

~~A future mailbox protocol might provide a simple ordered stream of typed
messages, with application records and dilation records mixed together.~~

## Dilation message over the mailbox

Each `DILATE-n` message is a JSON object with a `type` field that has a string value.
It might have other keys that depend upon the type.

### Initiating Dilation

For dilation to succeed, both sides must initate Dilation.
If both sides support Dilation but only one of them initiates it,
the initialization will stall and never complete.

Dilation is initiazed by sending a `please` (i.e. "please dilate") type message with a set of versions that can be accepted.
Versions use strings, rather than integers, to support experimental protocols, however there is still a total ordering of preferability.

```
{
  "type": "please",
  "side": "abcdef",
  // "accepted-versions": ["1"] TODO that field is not part of the Python implementation ~piegames
}
```

If one side receives a `please` before having initiated dilation itself,
the contents are stored in case it decides to do so in the future.
Once both sides have sent and received a `please` message,
the side determines whether it is the leader or the follower.
~~Both sides also compare `accepted-versions` fields to choose the best mutually-compatible
version to use: they should always pick the same one.~~
TODO that field is not part of the Python implementation ~piegames

### Establishing a Dilation connection

Then both sides begin the connection process by opening listening sockets and sending `connection-hint` messages for each one.
After a slight delay they will also open connections to the Transit Relay of their choice and produce hints for it too.
The receipt of inbound hints (on both sides) will trigger outbound connection attempts.
The hints are encoded as described in the Transit protocol.
(TODO specify the exact encoding, give examples ~piegames)

Some of these connections may succeed, and the Leader decides which to use (via an in-band signal on the established connection).
The others are dropped.

If something goes wrong with the established connection and the Leader decides a new one is necessary,
the Leader will send a `reconnect` message over the Wormhole.
This might happen while connections are still being established,
or while the Follower thinks it still has a viable connection
(the Leader might observe problems that the Follower does not),
or after the Follower thinks the connection has been lost.
In all cases, the Leader is the only side which should send `reconnect`.

```json
{ "type": "reconnect" }
```

Upon receiving a `reconnect`, the Follower should stop any pending connection attempts and terminate any existing connections
(even if they appear viable).
Listening sockets may be retained, but any previous connection made through them must be dropped.

Once all connections have stopped, the Follower should send a `reconnecting` message,
then start the connection process for the next generation,
which will send new `connection-hint` messages for all listening sockets.

```json
{ "type": "reconnecting" }
```

The Leader will drop all existing connections from before sending the `reconnect`,
and will not initiate any new connections until it receives the matching `reconnecting` from the Follower.
The Follower must drop all previous connections before it sends the `reconnecting` response.

~~(TODO: what about a follower->leader connection that was started before
start-dilation is received, and gets established on the Leader side after
start-dilation is sent? the follower will drop it after it receives
start-dilation, but meanwhile the leader may accept it as gen2 ~warner)~~

(probably need to include the generation number in the handshake, or in the
derived key ~warner — please please don't ~piegames)

(TODO: reduce the number of round-trip stalls here, I've added too many ~warner)
(yes, and one could also drastically reduce the number of messages by sending
all hints at once with the reconnect message ~piegames)

Hints can arrive at any time. One side might immediately send hints that can be computed quickly,
then send additional hints later as they become available.
For example, it might enumerate the local network interfaces and send hints for all of the LAN addresses first,
then send port-forwarding (UPnP) requests to the local router.
When the forwarding is established (providing an externally-visible IP address and port),
it can send additional hints for that new endpoint.
If the other peer happens to be on the same LAN,
the local connection can be established without waiting for the router's response.

(I'd like to see that feature removed, this stuff is already complicated enough with a signle hints message ~piegames)

### Connection Hint Format

TODO delegate this to Transit

## Dilation connection

TODO document the special relay handshake (it's the same as in Transit) ~piegames

TODO How does this part of the protocol interact with web clients and WebSocket
connections? ~piegames

Upon established connection (or at least a viable candidate), both sides send their handshake message.
The Leader sends "Magic-Wormhole Dilation Handshake v1 Leader\n\n".
The Follower sends "Magic-Wormhole Dilation Handshake v1 Follower\n\n".
This should trigger an immediate error for most non-magic-wormhole listeners
(e.g. HTTP servers that were contacted by accident).
If the wrong handshake is received, the connection will be dropped.
For debugging purposes, the node might want to keep looking at data beyond the first incorrect character
and log a few hundred characters until the first newline.

Everything after that point is a Noise protocol message,
which consists of a 4-byte big-endian length field, followed by a matching amount of bytes.
This uses the `NNpsk0` pattern with the Leader as the first party ("-> psk, e" in the Noise spec),
and the Follower as the second ("<- e, ee").
The pre-shared-key is the "dilation key", which is statically derived from the master PAKE key using HKDF.
(TODO how? ~piegames)
Each connection uses the same pre-shared key, but different ephemeral keys, so each gets a different session key.

The Leader sends the first message, which is a psk-encrypted ephemeral key.
The Follower sends the next message, its own psk-encrypted ephemeral key.
These two messages are known as "handshake messages" in the Noise protocol,
and must be processed in a specific order
(the Leader must not accept the Follower's message until it has generated its own).
Noise allows handshake messages to include a payload, but we do not use this feature.

All subsequent messages as known as "Noise transport messages", and are independent for each direction.
Transport messages are encrypted by the shared key, in a form that evolves as more messages are sent.

The Follower's first transport message is an empty packet, which we use as a "key confirmation message" (KCM).

The Leader doesn't send a transport message right away: it waits to see the Follower's KCM,
which indicates this connection is viable (i.e. the Follower used the same dilation key as the Leader,
which means they both used the same wormhole code).

Multiple connection attempts and handshakes may happen in parallel.
Of those where the Leader received a KCM, it chooses one of them to be actually used.
It will send an empty KCM to the Follower to mark that connection, and close all others.
All other connection attempts on both sides will be cancelled.
All listening sockets may or may not be shut down (TODO: think about it ~warner).

### Messages over the Dilation connection

Unlike with applications using Transit,
the application layer messages are not sent directly over the Dilation connection.
Instead, they get wrapped by this middle layer which provides the following features:

- Sub-channel multiplexing
- Pings and ACKs for connection status tracking
- Automatic reconnection after connection loss
- Durable channel with automatic re-transmission of lost messages after reconnect

~~In the future, we might have L2 links that are less connection-oriented,
which might have a unidirectional failure mode, at which point we'll need to
monitor full roundtrips. To accomplish this, the Leader will send periodic
unconditional PINGs, and the Follower will respond with PONGs. If the
Leader->Follower connection is down, the PINGs won't arrive and no PONGs will
be produced. If the Follower->Leader direction has failed, the PONGs won't
arrive. The delivery of both will be delayed by actual data, so the timeouts
should be adjusted if we see regular data arriving.~~

If the Leader loses the Dilation connection for whatever reason, it will initiate a reconnection attempt.
This involves sending a `reconnect` message and according hints over the Mailbox connection,
the same way as for initially establishing the connection.
Once a new connection is established and the handshake completes,
both sides re-transmit their outbound messages that were lost due to the connection interruption.

Each message over the Dilation connection starts with a one-byte type indicator.
The rest of the message depends upon the type:

* 0x00 PING, 4-byte ping-id
* 0x01 PONG, 4-byte ping-id
* 0x02 OPEN, 4-byte subchannel-id, 4-byte seqnum
* 0x03 DATA, 4-byte subchannel-id, 4-byte seqnum, variable-length payload
* 0x04 CLOSE, 4-byte subchannel-id, 4-byte seqnum
* 0x05 ACK, 4-byte response-seqnum

TODO it would make more sense to have the seqnum before the subchannel-id, processing wise ~piegames

#### Pings

PING and PONG messages are regularly exchanged to monitor the status of the connection.
They also serve to keep NAT entries alive, since some firewalls have unreasonably low connection timeouts
and may cause connection drops otherwise.

Our goals are:

* don't allow more than 30? seconds to pass without at least *some* data
  being sent along each side of the connection
* allow the Leader to detect silent connection loss within 60? seconds
* minimize overhead

We need both sides to:

* maintain a 30-second repeating timer
* set a flag each time we write to the connection
* each time the timer fires, if the flag was clear then send a PONG,
  otherwise clear the flag

In addition, the Leader must:

* run a 60-second repeating timer (ideally somewhat offset from the other)
* set a flag each time we receive data from the connection
* each time the timer fires, if the flag was clear then drop the connection,
  otherwise clear the flag

Receiving any PING will provoke a PONG in response, with a copy of the ping-id field.
The 30-second timer will produce unprovoked PONGs with a ping-id of all zeros.
A future viability protocol might use PINGs to test for roundtrip functionality.

#### Durable channel / Sequence numbers and ACKs

The OPEN, DATA, CLOSE and ACK messages all contain a big-endian encoded sequence number.
They start at 0, and monotonically increment for each new message
(except ACKs, which use the sequence number of the acknowledged message).
Each direction has a separate number space and counter.

When sending a message, it must be stored locally until a matching acknowledgement arrives.
When receiving a message, it must be acknowledged by sending a corresponding ACK message.
If the connection breaks down, all locally un-acked messages must be re-sent upon reconnect.
Clients only need to track the highest ACK value they received,
therefore one can acknowledge multiple messages with one ACK.
Messages may arrive multiple times; received messages with old sequence numbers must be ignored.
New messages must be sent strictly in order.

#### Sub-channel multiplexing

The DATA payloads are multiplexed over some virtual sub-channels. They may be
exposed to the application as logically independent data streams.

Each subchannel uses a distinct subchannel-id, which is a big-endian four-byte identifier.
Both directions share a number space (unlike the sequence numbers),
so the Dilation Leader uses odd numbers and the Follower uses even ones.
Id `0` is special and used for the control channel.
The control channel is always open; it cannot be opened nor closed explicitly.

Sub-channels may be opened with a OPEN message and closed with CLOSE messages.
Any side may close a channel. The other side, upon receiving that close message,
should stop sending new messages and confirm with a CLOSE message too.

DATA payloads that arrive for a non-open sub-channel should be ignored.
TODO can we please remove that sentence? ~piegames
Subchannel-ids should not be reused
(it would probably work, the protocol hasn't been analyzed enough to be sure).

The side that opens a sub-channel is named the Initiator, and the other side is named the Acceptor.
Subchannels can be initiated in either direction, independent of the Leader/Follower distinction.
For a typical file-transfer application, the subchannel would be initiated by the side seeking to send a file.

### Flow Control

TODO review and potentially remove? ~piegames

Subchannels are flow-controlled by pausing their writes when the L3
connection is paused, and pausing the L3 connection when the subchannel
signals a pause. When the outbound L3 connection is full, *all* subchannels
are paused. Likewise the inbound connection is paused if *any* of the
subchannels asks for a pause. This is much easier to implement and improves
our utilization factor (we can use TCP's window-filling algorithm, instead of
rolling our own), but will block all subchannels even if only one of them
gets full. This shouldn't matter for many applications, but might be
noticeable when combining very different kinds of traffic (e.g. a chat
conversation sharing a wormhole with file-transfer might prefer the IM text
to take priority).

Each subchannel implements Twisted's `ITransport`, `IProducer`, and
`IConsumer` interfaces. The Endpoint API causes a new `IProtocol` object to
be created (by the caller's factory) and glued to the subchannel object in
the `.transport` property, as is standard in Twisted-based applications.

All subchannels are also paused when the L3 connection is lost, and are
unpaused when a new replacement connection is selected.
