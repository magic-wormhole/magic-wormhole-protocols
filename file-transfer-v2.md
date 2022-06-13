# File-Transfer Protocol v2

This version 2 protocol is a complete replacement for the original (referred to as "v1") file-transfer protocol.

Both sides must support and use Dilation (see `dilation-protocol.md`).


## Overview and Features

We describe a flexible, "session"-based approach to file transfer allowing either side to offer files to send (while the other side may accept or reject each offer).
Either side may terminate the transfer session.

File are sent individually, with no dependency on zip or other archive formats.

Metadata is included in the offers to allow the receiver to decide if they want that file before the transfer begins.


## Protocol Details

See the Dilation document for details on the Dilation setup procedure.
Once a Dilation-supporting connection is open, we will have a "control" subchannel (subchannel #0).

All offers are sent over the control channel.
All answers (accept or reject) are also sent over the control channel.
All control-channel messages are encoded using `msgpack`.
   --> XXX: see "message encoding" discussion

Control-channel message formats are described using Python3 pseudo-code to illustrate the exact data types involved.

All control-channel messages contain an integer "kind" field describing the type of message.

Offer messages look like this:

```python
class Offer:
    kind: int = 1    # "offer"
    id: int          # unique random identifier for this offer
    filename: str    # utf8-encoded unicode relative pathname
    timestamp: int   # Unix timestamp (seconds since the epoch in GMT)
    bytes: int       # total number of bytes in the file
    subchannel: int  # the subchannel which the file will be sent on
```

The subchannel in an Offer MUST NOT match any subchannel in any existing Offer from this side nor from the other side.
This is enforced by the Dilation implementation: the Leader allocates only odd channels (starting with 1) and the Follower allocates only even channels (starting with 2).
That is, the side producing the Offer first opens a subchannel and then puts the resulting ID into the Offer message.

There are two kinds of repies to an offer, either an Accept message or a Reject message.
Reject messages look like this:

```python
class OfferReject:
    kind: int = 2    #  "offer reject"
    id: int          # matching identifier for an existing offer from the other side
    reason: str      # utf8-encoded unicode string describing why the offer is rejected
```

Accept messages look like this:

```python
class OfferAccept:
    kind: int = 3    #  "offer accpet"
    id: int          # matching identifier for an existing offer from the other side
```

When the offering side gets an `OfferReject` message, the subchannel is immediately closed.
The offering side may show the "reason" string to the user.
This offer ID should never be re-used during this session.

When the offering side gets an `OfferAccept` message it begins streaming the file over the already-opened subchannel.
When completed, the subchannel is closed.

That is, the offering side always initiates the open and close of the corresponding subchannel.

See examples down below.


## Discussion and Open Questions

* (sub)versioning of this protocol

It is likely useful to assign version numbers to either the protocol or to Offer messages.
This would allow future extensions such as adding more metadata to the Offer (e.g. `thumbnail: bytes`).

The simplest would be to version the entire protocol.
If we versioned the Offer messages, it's not clear what should happen if an old client receives a too-new Offer. Presumably, reject it -- but it would be better to let the sender know that the client is old and to re-send an older style offer.

To version the entire protocol we'd have to have each side send an initial control-channel message indicating what version they support.
Perhaps this could be stated as "features" instead (e.g. "thumbnail" feature if we added that, or "extended metadata" if we add more metadata, etc).
Using "features" would have the added semantic benefit that two up-to-date clients may still not want (or be able to use) particular features (e.g. a CLI client might not display thumbnails) but is more complex for both sides.

Preliminary conclusion: a simple Version message is sent first, with version=0.

* message encoding

While `msgpack` is mentioned above, there are several other binary-supporting libraries worth considering.
These are (in no particular order) at least: CBOR or flatbuffers or protocolbuffers or cap'n'proto


## Example 1

Alice contacts Bian to transfer a single file.

* The software on Alice's computer begins a Dilation-enabled session, producing a secret code.
* Alice sends this code to Bian
* Software on Bian's computer uses the code to complete the Dilation-enabled session.

At this point, Alice and Bian are connected (possibly directly, possibly via the relay).
Alice is the "Leader" in the Dilation protocol.
From this point on, the "file transfer v2" protocol is spoken (see below for `seqdiag` markup to render a diagarm).

* Alice opens a new subchannel (id=1, because she's the Leader)
* Alice sends an Offer to Bian on the control channel
* Bian accepts the Offer
* Alice sends all data on subchannel 1
* Alice closes subchannel 1
* Bian closes the mailbox
* Alice also closes the mailbox (which is now de-allocated on the server)

Here is a sequence diagram of the above.

```seqdiag
seqdiag {
    Alice -> Bian [label="OPEN(subchannel=1)"]
    Alice -> Bian [label="control \n Offer[filename=foo, subchannel=1, id=42]"]

    Alice <- Bian [label="control \n Accept[id=42]"]

    Alice -> Bian [label="subchannel 1 \n DATA"]
    Alice -> Bian [label="subchannel 1 \n DATA"]
    Alice -> Bian [label="subchannel 1 \n DATA"]

    Alice -> Bian [label="CLOSE(subchannel=1)"]

    Alice -> Bian [label="close mailbox"]
}
```

## Example 2

Alice contacts Bian to start a file-transfer session, sending 2 files and receiving 1.

The software is started on Alice's computer which initiates a (Dilation-enabled) connection.
Alice communcates the secret code to Bian.
On Bian's computer, the (Dilation-enabled) software completes the connection.

So, we have a Dilation-enabled connection between Alice and Bian's computers.

```seqdiag
seqdiag {
    Alice -> Bian [label="OPEN(subchannel=1)"]
    Alice -> Bian [label="control \n Offer[filename=foo, subchannel=1, id=42]"]
    Alice -> Bian [label="OPEN(subchannel=3)"]
    Alice -> Bian [label="control \n Offer[filename=bar, subchannel=3, id=89]"]

    Alice <- Bian [label="control \n Accept[id=42]"]
    Alice -> Bian [label="subchannel 1 \n DATA"]

    Alice <- Bian [label="OPEN(subchannel=2)"]
    Alice <- Bian [label="control \n Offer[filename=quux, subchannel=2, id=65]"]

    Alice <- Bian [label="control \n Accept[id=89]"]
    Alice -> Bian [label="subchannel 3 \n DATA"]
    Alice -> Bian [label="subchannel 1 \n DATA"]
    Alice -> Bian [label="subchannel 3 \n DATA"]
    Alice -> Bian [label="subchannel 1 \n DATA"]

    Alice -> Bian [label="control \n Accept[id=65]"]
    Alice <- Bian [label="subchannel 2 \n DATA"]

    Alice -> Bian [label="CLOSE(subchannel=1)"]

    Alice <- Bian [label="subchannel 2 \n DATA"]
    Alice -> Bian [label="subchannel 3 \n DATA"]
    Alice -> Bian [label="subchannel 3 \n DATA"]

    Alice <- Bian [label="CLOSE(subchannel=2)"]
    Alice -> Bian [label="CLOSE(subchannel=3)"]

    Alice -> Bian [label="close mailbox"]
    Alice <- Bian [label="close mailbox"]
}
```

Breaking down all those messages at a high level this is what's happening:

* Alice is the "Leader" in the Dilation session (this affects the subchannel IDs).
* Alice opens subchannel 1 to allocate an id to send in the first Offer
* Alice sends the first Offer, of file `foo`.
* Alice opens subchannel 3 for the second Offer
* Alice sends the second Offer, of file `bar`
* Bian accepts the Offer for `foo`.
* Alice starts sending data for `foo` on subchannel 1.
* Bian opens subchannel 2
* Bian sends Offer of file `quux`
* Bian accepts Offer 89, for file `bar`
* Alice sends more data (2 packets each of `foo` and `bar` files)
* Alice accepts Offer 65, for file `quux`
* Bian sends first data of file `quux`
* Alice is done sending file `foo` and closes the subchannel
* Bian sends some data for `quux`
* Alice sends 2 more chunks of data for `bar`
* Bian is done sending `quux` and closes the subchannel
* Alice is done sending `bar` and closes the subchannel
* Alice indicates she is done with the session and closes the mailbox
* Bian acknowledges and also closes the mailbox
