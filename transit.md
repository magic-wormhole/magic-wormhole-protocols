# Transit Protocol

The Wormhole API does not currently provide for large-volume data transfer
(this feature will be added to a future version, under the name "Dilated
Wormhole"). For now, bulk data is sent through a "Transit" object, which does
not use the Rendezvous Server. Instead, it tries to establish a direct TCP
connection from sender to recipient (or vice versa). If that fails, both
sides connect to a "Transit Relay", a very simple Server that just glues two
TCP sockets together when asked.

The Transit protocol is responsible for establishing an encrypted
bidirectional record stream between two programs. It must be given a "transit
key" and a set of "hints" which help locate the other end (which are both
delivered by Wormhole).

The protocol tries hard to create a **direct** connection between the two
ends, but if that fails, it uses a centralized relay server to ferry data
between two separate TCP streams (one to each client). Direct connection
hints are used for the first, and relay hints are used for the second.

The current implementation starts with the following:

* detect all of the host's IP addresses
* listen on a random TCP port
* offers the (address,port) pairs as hints

The other side will attempt to connect to each of those ports, as well as
listening on its own socket. After a few seconds without success, they will
both connect to a relay server.

## Roles

The Transit protocol has pre-defined "Leader" and "Follower" roles (unlike
Wormhole, which is symmetric/nobody-goes-first), which are called "Sender" and "Receiver"
for historical reasons. Each connection must have exactly one Sender and exactly one Receiver.
If the application using transfer does not provide this distinction, some deterministic
way for distributing the roles must be used. This could be done by comparing each
participant's `side` in the Wormhole.

The connection itself is bidirectional: either side can send or receive
records. However the connection establishment mechanism needs to know who is
in charge, and the encryption layer needs a way to produce separate keys for
each side.

This may be relaxed in the future, much as Wormhole was.

## Abilities

Each Transit object has a set of "abilities". These are outbound connection
mechanisms that the client is capable of using. The basic CLI tool (running
on a normal computer) has these abilities: `direct-tcp-v1`, `relay-v1`,
`tor-tcp-v1`, `direct-ws-v1` and `direct-wss-v1`.

* `direct-tcp-v1` indicates that it can make direct outbound TCP connections to a
  requested host and port number.
* `relay-v1` indicates it can connect to the Transit Relay and speak the
  matching protocol.
* `tor-tcp-v1`

Future implementations may have additional abilities, such as connecting
directly to Tor onion services, I2P services, WebSockets, WebRTC, or other
connection technologies. Implementations on some platforms (such as web
browsers) may lack `direct-tcp-v1` or `relay-v1`.

Together with each ability, the Transit object can create a
list of "hints", which tell the respective handshake how to find the other side.
Hints usually contain a `hostname`, a `port` and an optional `priority`.
Each hint will fall under one of the abilities that the peer indicated it
could use. Hints have types like `direct-tcp-v1`, `tor-tcp-v1`, and
`relay-v1`.

For example, if our peer can use `direct-tcp-v1`, then our Transit object
will deduce our local IP addresses (unless forbidden, i.e. we're using Tor),
listen on a TCP port, then send a list of `direct-tcp-v1` hints pointing at
all of them. If our peer can use `relay-v1`, then we'll connect to our relay
server and give the peer a hint to the same.

`tor-tcp-v1` hints indicate an Onion service, which cannot be reached without
Tor. `direct-tcp-v1` hints can be reached with direct TCP connections (unless
forbidden) or by proxying through Tor. Onion services take about 30 seconds
to spin up, but bypass NAT, allowing two clients behind NAT boxes to connect
without a transit relay (really, the entire Tor network is acting as a
relay).

## Handshake (`direct-tcp-v1`, `tor-tcp-v1`)

The transit key is used to derive several secondary keys. Two of them are
used as a "handshake", to distinguish correct Transit connections from other
programs that happen to connect to the Transit sockets by mistake or malice.

The handshake is also responsible for choosing exactly one TCP connection to
use, even though multiple outbound and inbound connections are being
attempted.

The SENDER-HANDSHAKE is the string `transit sender %s ready\n\n`, with the
`%s` replaced by a hex-encoded 32-byte HKDF derivative of the transit key,
using a "context string" of `transit_sender`. The RECEIVER-HANDSHAKE is the
same but with `receiver` instead of `sender` (both for the string and the
HKDF context).

The handshake protocol is like this:

* immediately upon connection establishment, the Sender writes
  SENDER-HANDSHAKE to the socket (regardless of whether the Sender initiated
  the TCP connection, or was listening on a socket and accepted the
  connection)
* likewise the Receiver immediately writes RECEIVER-HANDSHAKE to either kind
  of socket
* if the Sender sees anything other than RECEIVER-HANDSHAKE as the first
  bytes on the wire, it hangs up
* likewise with the Receiver and SENDER-HANDSHAKE
* if the Sender sees that this is the first connection to get
  RECEIVER-HANDSHAKE, it sends `go\n`. If some other connection got there
  first, it hangs up (or sends `nevermind\n` and then hangs up, but this is
  mostly for debugging, and implementations should not depend upon it). After
  sending `go`, it switches to encrypted-record mode.
* if the Receiver sees `go\n`, it switches to encrypted-record mode. If the
  receiver sees anything else, or a disconnected socket, it disconnects.

To tolerate the inevitable race conditions created by multiple contending
sockets, only the Sender gets to decide which one wins: the first one to make
it past negotiation. Hopefully this is correlated with the fastest connection
pathway. The protocol ignores any socket that is not somewhat affiliated with
the matching Transit instance.

Hints will frequently point to local IP addresses (local to the other end)
which might be in use by unrelated nearby computers. The handshake helps to
ignore these spurious connections. It is still possible for an attacker to
cause the connection to fail, by intercepting both connections (to learn the
two handshakes), then making new connections to play back the recorded
handshakes, but this level of attacker could simply drop the user's packets
directly.

Any participant in a Transit connection (i.e. the party on the other end of
your wormhole) can cause their peer to make a TCP connection (and send the
handshake string) to any IP address and port of their choosing. The handshake
protocol is intended to make this no more than a minor nuisance.

## Relay Handshake (`direct-relay-v1`)

The **Transit Relay** is a host which offers TURN-like services for
magic-wormhole instances. Clients connect to the relay either via TCP
or via WebSocket with a handshake to determine which connection wants
to be connected to which.

When connecting to a relay, the Transit client first writes RELAY-HANDSHAKE
to the socket, which is `please relay %s\n`, where `%s` is the hex-encoded
32-byte HKDF derivative of the transit key, using `transit_relay_token` as
the context. The client then waits for `ok\n`.

The relay waits for a second connection that uses the same token. When this
happens, the relay sends `ok\n` to both, then wires the connections together,
so that everything received after the token on one is written out (after the
ok) on the other. When either connection is lost, the other will be closed
(the relay does not support "half-close").

When clients use a relay connection, they perform the usual sender/receiver
handshake just after the `ok\n` is received: until that point they pretend
the connection doesn't even exist.

Direct connections are better, since they are faster and less expensive for
the relay operator. If there are any potentially-viable direct connection
hints available, the Transit instance will wait a few seconds before
attempting to use the relay. If it has no viable direct hints, it will start
using the relay right away. This prefers direct connections, but doesn't
introduce completely unnecessary stalls.

The Transit client attempts connections to multiple relays, and uses
the first one that passes negotiation. Each side combines a
locally-configured hostname/port (usually "baked in" to the
application, and possibly hosted by the application author) with
additional hostname/port pairs that come from the peer. This way
either side can suggest the relays to use. The `wormhole` application
accepts configuration switch that takes as input, the relay server's
address, e.g.: `tcp:myrelay.example.org:12345` or
`ws://myrelay.example.org:4002` as command-line option to supply an
additional relay. The address has three elements: the protocol, the
hostname and the port. The connection hints provided by the Transit
instance include the locally-configured relay, along with the
dynamically-determined direct hints. Both should be delivered to the
peer.

## Encryption

If desired\*, transit provides an enrypted **record-pipe**, which means the two
sides can and receive whole records, rather than unframed bytes. This is a side-effect of the
encryption (which uses the NaCl "secretbox" function). The encryption adds 44
bytes of overhead to each record (4-byte length, 24-byte nonce, 32-byte MAC),
so you might want to use slightly larger records for efficiency. The maximum
record size is 2^32 bytes (4GiB). The whole record must be held in memory at
the same time, plus its ciphertext, so very large ciphertexts are not
recommended.

Transit provides **confidentiality**, **integrity**, and **ordering** of
records. Passive attackers can only do the following:

* learn the size and transmission time of each record
* learn the sending and destination IP addresses

In addition, an active attacker (e.g. a malicious relay) is able to:

* delay delivery of individual records, while maintaining ordering (if they
  delay record #4, they must delay #5 and later as well)
* terminate the connection at any time

If either side receives a corrupted or out-of-order record, they drop the
connection. Attackers cannot modify the contents of a record, or change the
order of the records, without being detected and the connection being
dropped. If a record is lost (e.g. the receiver observes records #1,#2,#4,
but not #3), the connection is dropped when the unexpected sequence number is
received.

\* Most applications will likely want to use this. However, if applications prefer
doing their own crypto (e.g. because they tunnel SSH or TLS over transit), then
they can use the "raw" TCP stream built by Wormhole without the encrypted record pipes.

### Nonces

Each message contains a 24 bytes long nonce. The first nonce is all zeroes and is
incremented little endian for each record. As sender and receiver use different keys,
both sides have their own nonce.

For each received record, the nonce must be checked to be equal to the expected value,
which has to be tracked. Thus, there are 4 nonces in total, two per direction which are
kept in sync.
