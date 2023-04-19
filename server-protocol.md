# Mailbox Server Protocol

## Concepts

The Mailbox server provides queued delivery of binary messages from one
client to a second, and vice versa. Each message contains a "phase" (a
string) and a body (bytestring). These messages are queued in a "Mailbox"
until the other side connects and retrieves them, but are delivered
immediately if both sides are connected to the server at the same time.

Mailboxes are identified by a large random string. "Nameplates", in contrast,
have short numeric identities: in a wormhole code like "4-purple-sausages",
the "4" is the nameplate.

Each client has a randomly-generated "side", a short hex string, used to
differentiate between echoes of a client's own message, and real messages
from the other client.

## Application IDs

The server isolates each application from the others. Each client provides an
"App Id" when it first connects (via the "BIND" message), and all subsequent
commands are scoped to this application. This means that nameplates
(described below) and mailboxes can be re-used between different apps. The
AppID is a unicode string. Both sides of the wormhole must use the same
AppID, of course, or they'll never see each other. The server keeps track of
which applications are in use for maintenance purposes.

Each application should use a unique AppID. Developers are encouraged to use
"DNSNAME/APPNAME" to obtain a unique one: e.g. the `bin/wormhole`
file-transfer tool uses `lothar.com/wormhole/text-or-file-xfer`.

## WebSocket Transport

At the lowest level, each client establishes (and maintains) a WebSocket
connection to the Mailbox server. If the connection is lost (which could
happen because the server was rebooted for maintenance, or because the
client's network connection migrated from one network to another, or because
the resident network gremlins decided to mess with you today), clients should
reconnect after waiting a random (and exponentially-growing) delay. The
Python implementation waits about 1 second after the first connection loss,
growing by 50% each time, capped at 1 minute.

Each message to the server is a dictionary, with at least a `type` key, and
other keys that depend upon the particular message type. Messages from server
to client follow the same format.

`misc/dump-timing.py` is a debug tool which renders timing data gathered from
the server and both clients, to identify protocol slowdowns and guide
optimization efforts. To support this, the client/server messages include
additional keys. Client->Server messages include a random `id` key, which is
copied into the `ack` that is immediately sent back to the client for all
commands (logged for the timing tool but otherwise ignored). Some
client->server messages (`list`, `allocate`, `claim`, `release`, `close`,
`ping`) provoke a direct response by the server: for these, `id` is copied
into the response. This helps the tool correlate the command and response.
All server->client messages have a `server_tx` timestamp (seconds since
epoch, as a float), which records when the message left the server. Direct
responses include a `server_rx` timestamp, to record when the client's
command was received. The tool combines these with local timestamps (recorded
by the client and not shared with the server) to build a full picture of
network delays and round-trip times.

All messages are serialized as JSON, encoded to UTF-8, and the resulting
bytes sent as a single "binary-mode" WebSocket payload.

Servers can signal `error` for any message type it does not recognize.
Clients and Servers must ignore unrecognized keys in otherwise-recognized
messages. Clients must ignore unrecognized message types from the Server.

## Connection-Specific (Client-to-Server) Messages

The first thing the server sends to each client is the `welcome` message.
This is intended to deliver important status information to the client that
might influence its operation. Clients should look out for the following fields,
and handle them accordingly, if present:

* `current_cli_version`: *(deprecated)* prompts the user to upgrade if the server's
  advertised version is greater than the client's version (as derived from
  the git tag)
* `motd`: This message is intended to inform users about
  performance problems, scheduled downtime, or to beg for donations to keep
  the server running. Clients should print it or otherwise display prominently
  to the user. The value *should* be a plain string.
* `error`: The client should show this message to the user and then terminate.
  The value *should* be a plain string.
* `permission-required`: a set of available authentication methods,
  proof of work challenges etc. The client needs to "solve" one of
  them in order to get access to the service.

Other (unknown) fields should be ignored.
The client should examine the `permissions-required` methods (if
present) and select one to use (see also "Permission to Use the
Server" below).

* If the client doesn't send a `submit-permissions` message (or it is
  invalid or otherwise unacceptable) the server either proceeds anyway
  (because it is allowing all access) or sends a "permission denied"
  error message and closes the connection.

* If the client doesn't support any permissions methods it should show
  an error to the user and disconnect. (If the server is allowing
  permission-less connections it should include the method `none` in
  its list).

* Backwards compatibility: older clients will always send the `bind`
  message immediately (without waiting for the `welcome` message). The
  server responds the same way as if the client had sent no
  `submit-permissions` message (see above).

The `bind` message specifies the AppID and side (in keys `appid` and
`side`, respectively) that all subsequent messages will be scoped to.
While technically each message could be independent (with its own
`appid` and `side`), I thought it would be less confusing to use
exactly one WebSocket per logical wormhole connection.

A `ping` will provoke a `pong`: these are only used by unit tests for
synchronization purposes (to detect when a batch of messages have been fully
processed by the server). NAT-binding refresh messages are handled by the
WebSocket layer (by asking Autobahn to send a keepalive messages every 60
seconds), and do not use `ping`.

If any client->server command is invalid (e.g. it lacks a necessary key, or
was sent in the wrong order), an `error` response will be sent, This response
will include the error string in the `error` key, and a full copy of the
original message dictionary in `orig`.


## Permission to Use the Server

Server operators may wish to deny service to some clients. We
generally refer to this as "Permission" and imagine future additions
of use-cases and methods, although only one such pair is decribed
currently.

One such use-case is if the server is under a Denial of Service (DoS)
attack or other malicious activity. We describe a "proof of work"
scheme for clients to gain permission to use a server under DoS
attack.

In the `welcome` message the server may include a `permission-required` key. If provided, this will point to a `dict` with one key per supported method along with any method-specific options.
For example:

    {
        "none": {}
        "hashcash": {
            "bits": 6,
            "resource": "resource-string"
        }
    }

Currently, the following are supported by the protocol:

* `none`: no permission required, send a normal `bind`.
* `hashcash`: Includes keys for `bits` and `resource` used for input
   as per the [Hashcash](http://hashcash.org) specifications. The
   resource string is arbitrary and the client shouldn't depend on any
   structure in it. The resource string cannot contain a `:`
   character. The client must include a reply that conforms to the
   [Hashcash
   v1](http://hashcash.org/docs/hashcash.html#stamp_format__version_1_)
   format in the `submit-permissions` message:

    {
        "method": "hashcash",
        "stamp": "1:6:210723:resource-string::NmZNF4eIbk87mqYz:000003n"
    }

The above stamp was generated with `hashcash -b 6 -m
"resource-string"`. Note that the number of bits is quite likely to be
higher than 6 (hashcash specifies 20 as the default). Servers may
choose any number and may increase it if usage or abuse is too high.

More methods may be added to the protocol in future. Clients must
ignore methods they do not support. Clients may choose any supported
method.

Using TLS is strongly encouraged. This at minimum increases privacy of
clients. Using any permission methods with a bearer-token-like scheme
(as hashcash does above) over an insecure connections allows passive
observers to use the hard-earned token for themselves.


## Nameplates

Wormhole codes look like `4-purple-sausages`, consisting of a number followed
by some random words. This number is called a "Nameplate".

On the Mailbox server, the Nameplate contains a pointer to a Mailbox.
Clients can "claim" a nameplate, and then later "release" it. Each claim is
for a specific side (so one client claiming the same nameplate multiple times
only counts as one claim). Nameplates are deleted once the last client has
released it, or after some period of inactivity.

Clients can either make up nameplates themselves, or (more commonly) ask the
server to allocate one for them. Allocating a nameplate automatically claims
it (to avoid a race condition), but for simplicity, clients send a claim for
all nameplates, even ones which they've allocated themselves.

Nameplates (on the server) must live until the second client has learned
about the associated mailbox, after which point they can be reused by other
clients. So if two clients connect quickly, but then maintain a long-lived
wormhole connection, they do not need to consume the limited space of short
nameplates for that whole time.

The `allocate` command allocates a nameplate (the server returns one that is
as short as possible), and the `allocated` response provides the answer.

There is a `list` command (with the answer message being `nameplates`) intended
for the use-case of listing currently in-use nameplates for user input
auto-completion purposes. However, this feature could trivially be used to
disrupt the service, therefore servers may send an always-empty response to not
disclose any information about in-use nameplates.

## Mailboxes

The server provides a single "Mailbox" to each pair of connecting Wormhole
clients. This holds an unordered set of messages, delivered immediately to
connected clients, and queued for delivery to clients which connect later.
Messages from both clients are merged together: clients use the included
`side` identifier to distinguish echoes of their own messages from those
coming from the other client.

Each mailbox is "opened" by some number of clients at a time, until all
clients have closed it. Mailboxes are kept alive by either an open client, or
a Nameplate which points to the mailbox (so when a Nameplate is deleted from
inactivity, the corresponding Mailbox will be too).

The `open` command both marks the mailbox as being opened by the bound side,
and also adds the WebSocket as subscribed to that mailbox, so new messages
are delivered immediately to the connected client. There is no explicit ack
to the `open` command, but since all clients add a message to the mailbox as
soon as they connect, there will always be a `message` response shortly after
the `open` goes through. The `close` command provokes a `closed` response.

The `close` command accepts an optional "mood" string: this allows clients to
tell the server (in general terms) about their experiences with the wormhole
interaction. The server records the mood in its "usage" record, so the server
operator can get a sense of how many connections are succeeding and failing.
The moods currently recognized by the Mailbox server are:

* `happy` (default): the PAKE key-establishment worked, and the client saw at
  least one valid encrypted message from its peer
* `lonely`: the client gave up without hearing anything from its peer
* `scary`: the client saw an invalid encrypted message from its peer,
  indicating that either the wormhole code was typed in wrong, or an attacker
  tried (and failed) to guess the code
* `errory`: the client encountered some other error: protocol problem or
  internal error

The server will also record `pruney` if it deleted the mailbox due to
inactivity, or `crowded` if more than two sides tried to access the mailbox.

When clients use the `add` command to add a client-to-client message, they
will put the body (a bytestring) into the command as a hex-encoded string in
the `body` key. They will also put the message's "phase", as a string, into
the `phase` key. See client-protocol.md for details about how different
phases are used.

When a client sends `open`, it will get back a `message` response for every
message in the mailbox. It will also get a real-time `message` for every
`add` performed by clients later. These `message` responses include "side"
and "phase" from the sending client, and "body" (as a hex string, encoding
the binary message body). The decoded "body" will either by a random-looking
cryptographic value (for the PAKE message), or a random-looking encrypted
blob (for the VERSION message, as well as all application-provided payloads).
The `message` response will also include `id`, copied from the `id` of the
`add` message (and used only by the timing-diagram tool).

The Mailbox server does not de-duplicate messages, nor does it retain
ordering: clients must do both if they need to.

## All Message Types

This lists all message types, along with the type-specific keys for each (if
any), and which ones provoke direct responses:

* S->C welcome {welcome: {permission-required: hashcash: {}}
* (C->S) submit-permissions {..} (optional)
* (C->S) bind {appid:, side:, }
* (C->S) list {} -> nameplates
* S->C nameplates {nameplates: [{id: str},..]} (response might be empty)
* (C->S) allocate {} -> allocated
* S->C allocated {nameplate:}
* (C->S) claim {nameplate:} -> claimed
* S->C claimed {mailbox:}
* (C->S) release {nameplate:?} -> released
* S->C released
* (C->S) open {mailbox:}
* (C->S) add {phase: str, body: hex} -> message (to all connected clients)
* S->C message {side:, phase:, body:, id:}
* (C->S) close {mailbox:?, mood:?} -> closed (the mailbox is known and implicit to the current connection)
* S->C closed
* S->C ack
* (C->S) ping {ping: int} -> ping
* S->C pong {pong: int}
* S->C error {error: str, orig:}

## Persistence

The server stores all messages in a database, so it should not lose any
information when it is restarted. The server will not send a direct
response until any side-effects (such as the message being added to the
mailbox) have been safely committed to the database.

The client library knows how to resume the protocol after a reconnection
event, assuming the client process itself continues to run.

Clients which terminate entirely between messages (e.g. a secure chat
application, which requires multiple wormhole messages to exchange
address-book entries, and which must function even if the two apps are never
both running at the same time) can use "Journal Mode" to ensure forward
progress is made: see "journal.md" for details.
