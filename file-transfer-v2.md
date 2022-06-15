# File-Transfer Protocol v2

This version 2 protocol is a complete replacement for the original (referred to as "v1") file-transfer protocol.

Both sides must support and use Dilation (see `dilation-protocol.md`).

Any all-caps words ("MAY", "MUST", etc) follow RFC2119 conventions.

NOTE: there are several open questions / discussion points, some with corresponding "XXX" comments inline.


## Overview and Features

We describe a flexible, "session"-based approach to file transfer allowing either side to offer files to send while the other side may accept or reject each offer.
Either side MAY terminate the transfer session (by closing the wormhole)

File are offered and sent individually, with no dependency on zip or other archive formats.

Metadata is included in the offers to allow the receiver to decide if they want that file before the transfer begins.

Filenames are relative paths.
When sending individual files, this will be simply the filename portion (with no leading paths).
For a series of files in a directory (i.e. if a directory was selected to send) paths will be relative to that directory (starting with the directory itself).
(XXX see "file naming" in discussion)


## Version Negotiation

There is an existing file-transfer protocol which does not use Dilation.
Clients supporting newer versions of file-transfer (i.e. the one in this document) SHOULD offer backwards compatibility.

In the mailbox protocol, applications can indicate version information.
The existing file-transfer protocol doesn't use this so the version information is empty (indicating "version 1").
This protocol will include a dict like:

```json
{
    "transfer-v2": {
        "mode": "{send|receive|connect}",
        "formats": [1]
    }
}
```

The `mode` key indicates the desired mode of that peer.
It has one of three values:
* `"send"`: the peer will send a single file/text (similar to classic transfer protocol)
* `"receive"`: the peer will receive at most one file or text (the other side of the above)
* `"connect"`: the peer will send and receive zero or more files before closing the session

Note that `send` and `receive` above will still use Dilation as all clients supporting this protocol must.
If a peer sends no version information at all, it will be using the classic protocol (and is thus using Transit and not Dilation for the peer-to-peer connection).

The `formats` key is a list of message-formats understood by the peer.
This allows for existing messages like `Offer` to be extended, or for new message types to be added.
Peers MUST _accept_ messages for any formats they support.
Peers MUST only send messages for formats in the other side's list.
Only one format exists currently: `1`.
Future extensions to this protocol will document which format version any new attributes or messages belong to.

See "Example of Protocol Expansion" below for discussion about adding new attributes.


## Protocol Details

See the Dilation document for details on the Dilation setup procedure.
Once a Dilation-supporting connection is open, we will have a "control" subchannel (subchannel #0).

All offers MUST be sent over the control channel.
All answers (accept or reject) MUST also be sent over the control channel.
All control-channel messages MUST be encoded using `msgpack`.
   --> XXX: see "message encoding" discussion

Control-channel message formats are described using Python pseudo-code to illustrate the exact data types involved.

All control-channel messages contain an integer "kind" field describing the type of message.

XXX: Rejected idea: Version message, because we already do version negotiation via mailbox features.

Either side MAY send any number of Offer messages at any time after the connection is set up.
They MUST first open a subchannel to receive the subchannel ID.
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

The `id` in an Offer MUST NOT match any other Offer from this side.
The subchannel in an Offer MUST NOT match any subchannel in any existing Offer from this side nor from the other side.
This latter constraint is enforced by the Dilation implementation: the Leader allocates only odd channels (starting with 1) and the Follower allocates only even channels (starting with 2).
That is, the side producing the Offer first opens a subchannel and then puts the resulting ID into the Offer message.

There are two kinds of repies to an offer: either an Accept message or a Reject message.
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

When the offering side gets an `OfferReject` message, the subchannel SHOULD be immediately closed.
The offering side MAY show the "reason" string to the user.
Any send Offer ID MUST NOT be re-used during this session.

When the offering side gets an `OfferAccept` message it begins streaming the file over the already-opened subchannel.
When completed, the subchannel is closed.

That is, the offering side always initiates the open and close of the corresponding subchannel.

Each side may also send a free-form text message at any time.
These messages look like:

```python
class Message:
    message: str     # unicode string
    kind: int = 4    # "text message"
````

See examples down below, after "Discussion".


## Discussion and Open Questions

* overall selection of "classic" or "v2" file-transfer

How will clients select between "classic" file-transfer support and Dilation-enabled v2 support?

Perhaps it is sufficient to trigger that on whether Dilation negotiation worked or not: if we have a Dilation connection, then we do "v2 file-transfer" (and use sub-versions to select features there, see next open question).
If we do not, then "classic" / v1 file-transfer is used.

* (sub)versioning of this protocol

Might it be useful to assign version numbers to either the protocol (e.g. an initial Version message?) or to Offer messages.
This would allow future extensions such as adding more metadata to the Offer (e.g. `thumbnail: bytes`).
Or, do we just use the existing versioning?
Or, do we just insist that clients ignore unknown keys in Offer/etc messages? (Allowing extensions, but if we want to _depend_ on those extras, it needs a whole new protocol version?)

The simplest would be to version the entire protocol.
If we versioned the Offer messages, it's not clear what should happen if an old client receives a too-new Offer. Presumably, reject it -- but it would be better to let the sender know that the client is old and to re-send an older style offer.

To version the entire protocol we'd have to have each side send an initial control-channel message indicating what version they support.
Perhaps this could be stated as "features" instead (e.g. "thumbnail" feature if we added that, or "extended metadata" if we add more metadata, etc).
Using "features" would have the added semantic benefit that two up-to-date clients may still not want (or be able to use) particular features (e.g. a CLI client might not display thumbnails) but is more complex for both sides.

Preliminary conclusion: a simple Version message is sent first, with version=0.

* message encoding

While `msgpack` is mentioned above, there are several other binary-supporting libraries worth considering.
These are (in no particular order) at least: CBOR or flatbuffers or protocolbuffers or cap'n'proto

* file naming

Sending a single file like `/home/meejah/Documents/Letter.docx` gets a filename like `Letter.docx`
Sending a whole directory like `/home/meejah/Documents/` would result in some number of offers like `Documents/Letter.docx` etc.

The question is, does this make sense?
Should there (instead) be at least two kinds of offer: single files, or "collections"?
Maybe _all_ offers should be collections, and a "single file offer" is just the special case where the list of offers has a single entry.


## File Naming Example

Given a hypothetical directory tree:

* /home/
  * meejah/
    * grumpy-cat.jpeg
    * homework-draft2-final.docx
    * project/
      * local-network.dia
      * traffic.pcap
      * README
      * src/
        * hello.py

As spec'd above, if the human selects `/home/meejah/project/src/hello.py` then it should be sent as `hello.py`.
However if they select `/home/meejah/project/` then there should be 4 offers: project/local-network.dia`, `project/traffic.pcap`, `project/README`, `project/src/hello.py`.

Another way to this could be to re-design Offer messages to look like this:

```python
class Offer:
    kind: int = 1    # "offer"
    id: int          # unique random identifier for this offer
    path: str        # utf8-encoded unicode relative base path of all files
    files: list      # contains FileOffer instances

class FileOffer:
    filename: str    # utf8-encoded unicode relative pathname
    timestamp: int   # Unix timestamp (seconds since the epoch in GMT)
    bytes: int       # total number of bytes in the file
    subchannel: int  # the subchannel which the file will be sent on
```

This would keep collections of files together (e.g. a subdirectory).
For a single file, `path` would be `"."`.
Maybe: single `subchannel` for all files? (No need for framing / EOF; we have length)


## Example of Protocol Expansion

Let us suppose that at some point in the future we decide to add `thumbnail: bytes` to the `Offer` messages.
We assign this format `2`, so `Offers` become:

```python
class Offer:
    kind: int = 1    # "offer"
    id: int
    filename: str
    timestamp: int
    bytes: int
    subchannel: int
    thumbnail: bytes  # introduced in format 2; PNG data
```

All existing implementations will have `"formats": [1]`.
A new thumbnail-supporting implementations will send `"formats": [1, 2]`.

A new peer speaking to an old peer will never see `thumbnail` in the Offers, because the old peer sent `"formats": [1]` so the new peer knows not to inclue that attribute (and the old peer won't ever send it).

Two new peers speaking will both send `"formats": [1, 2]` and so will both include (and know how to interpret) `"thumbnail"` attributes on `Offers`.

Additinoally, a new peer that _doesn't want_ to see `"thumbnail"` data (e.g. it's a CLI client) can not include `2` in their `"formats"` list.

XXX: perhaps the formats should be strings, like `["original", "thumbnail"]` for this example??


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
