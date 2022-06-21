# Dilated File-Transfer Protocol

This version of the file-transfer protocol is a complete replacement for the original (referred to as "classic") file-transfer protocol.

Both sides must support and use Dilation (see `dilation-protocol.md`).

Any all-caps words ("MAY", "MUST", etc) follow RFC2119 conventions.

NOTE: there are several open questions / discussion points, some with corresponding "XXX" comments inline.


## Overview and Features

We describe a flexible, "session"-based approach to file transfer allowing either side to offer files to send while the other side may accept or reject each offer.
Either side MAY terminate the transfer session (by closing the wormhole)
Either side MAY select a one-way version, similar to the classic protocol.

File are offered and sent individually, with no dependency on zip or other archive formats.

Metadata is included in the offers to allow the receiver to decide if they want that file before the transfer begins.

"Offers" generally correspond to what a user might select; a single-file offer is possible but so is a directory.
In both cases, they are treated as "an offer" although a directory may consist of dozens or more individual files.

Filenames are relative paths.
When sending individual files, this will be simply the filename portion (with no leading paths).
For a series of files in a directory (i.e. if a directory was selected to send) paths will be relative to that directory (starting with the directory itself).
(XXX see "file naming" in discussion)


## Version Negotiation

There is an existing file-transfer protocol which does not use Dilation (called "classic" in this document).
Clients supporting newer versions of file-transfer (i.e. the one in this document) SHOULD offer backwards compatibility.

In the mailbox protocol, applications can indicate version information.
The existing file-transfer protocol doesn't use this so the version information is empty (indicating "classic").
This protocol will include a dict like:

```json
{
    "transfer": {
        "version": 1,
        "mode": "{send|receive|connect}",
        "features": ["core"],
        "permission": "{ask|yes}"
    }
}
```

The `version` key indicates the highest version of this Dilated File Transfer protocol that this peer understands.
There is currently only one version: `1`.

The `mode` key indicates the desired mode of that peer.
It has one of three values:
* `"send"`: the peer will only send files (similar to classic transfer protocol)
* `"receive"`: the peer only receive files (the other side of the above)
* `"connect"`: the peer will send and receive zero or more files before closing the session

Note that `send` and `receive` above will still use Dilation as all clients supporting this protocol must.
If a peer sends no version information at all, it will be using the classic protocol (and is thus using Transit and not Dilation for the peer-to-peer connection).

The `"features"` key is a list of message-formats / features understood by the peer.
This allows for existing messages to be extended, or for new message types to be added.
Peers MUST _accept_ messages for any features they support.
Peers MUST only send messages for features in the other side's list.
Only one format exists currently: `"core"`.

   XXX:: maybe just lean on "version" for now?

See "Example of Protocol Expansion" below for discussion about adding new attributes (including when we might increment the `"version"` instead of adding a new `"feature"`).

The `"permission"` key specifies how to proceed with offers.
Using mode `ask` tells the sender to pause after transmitting the first metadata message and await an answer from the peer before streaming data.
Using mode `yes` means the peer will accept all incoming transfers so the sender should not pause after the metadata (and instead immediately start sending data messages).
This cuts down latency for "one-way" transfers (see "Discussion")


## Protocol Details

See the Dilation document for details on the Dilation setup procedure.
Once a Dilation-supporting connection is open, we will have a "control" subchannel (subchannel #0).
Either peer can also open additional subchannels.

All control-channel messages are encoded using `msgpack`.
   --> XXX: see "message encoding" discussion

Control-channel message formats are described using Python pseudo-code to illustrate the exact data types involved.

All control-channel messages contain an integer "kind" field describing the type of message.

Rejected idea: Version message, because we already do version negotiation via mailbox features.

Rejected idea: Offer/Answer messages via the control channel: we need to open a subchannel anyway; the subchannel-IDs are not intended to be part of the Dilation API.


### Control Channel Messages

Each side MAY send a free-form text message at any time.
These messages look like:

```python
class Message:
    message: str     # unicode string
    kind: int = 1    # "text message"
```


### Making an Offer

Either side MAY send any number of Offer messages at any time after the connection is set up.
If the other peer specified `"mode": "send"` then this peer MUST NOT make any offers.

To make an offer the peer opens a subchannel.
Recall from the Dilation specification that subchannels are _record_ pipes (not simple byte-streams).

All records on the subchannel are bytes, where the first byte indicates the kind of message and the remaining bytes are kind-dependant.

The following kinds of messages exist(indicated by the first byte):
* 1: msgpack-encoded `FileOffer` message
* 2: msgpack-encoded `DirectoryOffer` message
* 3: msgpack-encoded `OfferAccept` message
* 4: msgpack-encoded `OfferReejct` message
* 5: file data bytes

All other byte values are reserved for future use and MUST NOT be used.
XXX: maybe spec [0, 128) as reserved, and [128, 255) for "experiments"?

The first message sent on the new subchannel is one of two offer messages.

To offer a single file (with message kind `1`):

```python
class FileOffer:
    filename: str    # unicode relative pathname
    timestamp: int   # Unix timestamp (seconds since the epoch in GMT)
    bytes: int       # total number of bytes in the file
```

To offer a directory tree of many files (with message kind `2`):
```python
class DirectoryOffer:
    base: str          # unicode pathname of the root directory (i.e. what the user selected)
    size: int         # total number of bytes in _all_ files
    files: list[str]   # a list containing relative paths for each file
```

The filenames in the `"files"` list are  unicode relative paths (relative to the `"base"` from the `DirectoryOffer` and NOT including that part.

For example:

```python
DirectoryOffer(
    base="project",
    size: 165,
    files=["README", "src/hello.py"]
    ]
)
```

This indicates an offer to send two files, one in `"project/README"` and the other in `"project/src/hello.py"`.


What happens next depends on the mode of the peer.

If the peer has `"mode": "yes"` then this peer MUST immediately start sending content messages (see below).

If the peer has `"mode": "ask"` then this peer MUST NOT send any more messages and instead await an incoming message.

That incoming message MUST be one of two reply messages: `OfferAccept` or `OfferReject`.
These are indicated by the kind byte of that message being `3` or `4` (see list above).

```python
class OfferReject:
    reason: str      # unicode string describing why the offer is rejected
```

Accept messages are blank (that is, they are a single byte: `4`).

```python
class OfferAccept:
    pass
```

When the offering side gets an `OfferReject` message, the subchannel SHOULD be immediately closed.
The offering side MAY show the "reason" string to the user.

When the offering side gets an `OfferAccept` message it begins streaming the file over the already-opened subchannel.
When completed, the subchannel is closed.

That is, the offering side always initiates the open and close of the corresponding subchannel.

Messages of kind `5` ("file data bytes") consist solely of file data.
A single data message MUST NOT exceed 65536 (65KiB) inculding the single byte for "kind".
Applications are free to choose how to fragment the file data so long as no single message is bigger than 65536 bytes.
A good default to choose in 2022 is 16KiB (2^14 - 1 payload bytes)
XXX: what is a good default? Dilation doesn't give guidance either...

When sending a `DirectoryOffer` each individual file is preceeded by a `FileOffer` message. However the rules about "maybe wait for reply" no longer exist; that is, all file data SHOULD be immediately sent.

See examples down below, after "Discussion".


## Discussion and Open Questions

* Overall versioning considerations

Versioning is hard.

The existing file-transfer protocol does not include versioning.
Luckily, the mailbox protocol _itself_ allows for "application versioning" messages; this gives us an "out" here, effectively letting us send a "T minus 1" message via the "application version" dict.

We do not have another such escape hatch (i.e. "T minus 2"), so if we get it wrong (again) then we potentially have a painful upgrade path.

Currently, a file-transfer peer that sends zero version data is assumed to be "classic".
A file-transfer peer supporting Dilation and this new protocol sends `"transfer": {...}` as per the  "Version Negotiation" section above.
We include a `"version"` key in that dict so that this transfer protocol may be extended in the future (see "Protocol Expansion Exercises" below).

Additionally, a `"features"` key is included in that information.
Although releated, this is somewhat orthogonal to "versions".
That is, a peer may _know how to parse_ some (newer) version of this protocol but may still wish to _not_ support (or use) a particular feature.


* message encoding

While `msgpack` is mentioned above, there are several other binary-supporting libraries worth considering.
These are (in no particular order) at least: CBOR or flatbuffers or protocolbuffers or cap'n'proto

We could also still decide to simply use JSON, as that is also unambiguous.
Although it enjoys widespread support, JSON suffers from a lack of 64-bit integers (because JavaScript only supports 2^53 integers) and doesn't support a byte-string type (forcing e.g. any binary data to be encded in base64 or similar).

preliminary conclusion: msgpack.


* file naming

Sending a single file like `/home/meejah/Documents/Letter.docx` gets a filename like `Letter.docx`
Sending a whole directory like `/home/meejah/Documents/` would result in a directory-offer with basedir `Documents` and some number of files (possibly with sub-paths).

This does NOT offer a client the chance to select "this" and "that" from a Directory offer (however, see the "Protocol Expansion Execrises" section).

Preliminary conclusion: centering around "the thing a human would select" (i.e. "a file" or "a directory") makes the most sense.


* streaming data

There is no "finished" message. Maybe there should be? (e.g. the receiving side sends back a hash of the file to confirm it received it properly?)

Does "re-using" the `FileOffer` as a kind of "header" when streaming `DirectoryOffer` contents make sense?
We need _something_ to indicate the next file etc

Do the limits on message size make sense? Should "65KiB" be much smaller, potentially?
(Given that network conditions etc vary a lot, I think it makes sense for the _spec_ to be somewhat flexible here and "65k" doesn't seem very onerous for most modern devices / computers)


* compression

It may make sense to do compression of files.
See "Protocol Expansion Exercises" for more discussion.

Preliminary conclusion: no compression in this version.


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
However if they select `/home/meejah/project/` then there should be a Directory Offer offers like:

```python
DirectoryOffer(
    base="project",
    size=4444,
    files=[
        "local-network.dia",
        "traffic.pcap",
        "README",
        "src/hello.py"
    ]
)
```


## Protocol Expansion Exercises

Here we present several scenarios for different kinds of protocol expansion.
The point here is to discuss the _kinds_ of expansions that might happen.
The examples here ARE NOT part of the spec and SHOULD NOT be implemented.

That said, we believe they're realistic features that _could_ make sense in future protocol expansions.


### Thumbnails

Let us suppose that at some point in the future we decide to add `thumbnail: bytes` to the `Offer` messages.
It is reasonable to imagine that some clients may not make use of this feature at all (e.g. CLI programs) and so work and bandwidth can be saved by not producing and sending them.

This becomes a new `"feature"` in the protocol.
That is, the version information is upgraded to allow `"features": ["basic", "thumbnails"]`.

Peers that do not understand (or do not _want_) thumbnails do not include that in their `"features"` list.
So, according to the protocol, these peers should never receive anything related to thumbnails.
Only if both peers include `"features": ["basic", "thumbnails"]` will they receive thumbnail-related information.

The thumbnail feature itself could be implemented by expanding the `Offer` message:

```python
class Offer:
    filename: str
    timestamp: int
    bytes: int
    thumbnail: bytes  # introduced in "thumbnail" feature; PNG data
```
A new peer speaking to an old peer will never see `thumbnail` in the Offers, because the old peer sent `"formats": ["basic"]` so the new peer knows not to inclue that attribute (and the old peer won't ever send it).

Two new peers speaking will both send `"formats": ["basic", "thumbnails"]` and so will both include (and know how to interpret) `"thumbnail"` attributes on `Offers`.

Additionally, a new peer that _doesn't want_ to see `"thumbnail"` data (e.g. it's a CLI client) can simply not include `"thumbnail"` in their `"formats"` list even if their protocol implementation knows about it.


### Finer Grained Permissions

What if we decide we want to expand the "ask" behavior to sub-items in a Directory.

As this affects the behavior of both the sender (who now has to wait more often) and the receiver (who now has to send a new message) this means an overall protocol version bump.

(XXX _does_ it though? I think we could use `"formats"` here too...)

So, this means that `"version": 2` would be the newest version.
Any peer that sends a version lower than this (i.e. existing `1`) will not send any fine-grained information (or "yes" messages).
Any peer who sees the other side at a version lower than `2` thus cannot use this behavior and has to prtend to be a version `1` peer.

If both peers send `2` then they can both use the new behavior (still using the overall `"yes"` versus `"ask"` switch that exists now, probably).


### Compression

Suppose that we decide to introduce compression.

(XXX again, probably just "features"?)


### Big Change

What is a sort of change that might actually _require_ us to use the `"version": 2` lever?


### How to Represent Overall Version

It can be useful to send a "list of versions" you support even if the ultimate outcome of a "version negotiation" is a single scalar (of "maximum version").

Something to do with being able to release (and then revoke) particular (possibly "experimental") versions.

There may be an example in the TLS history surrounding this.

This means we might want `"version": [1, 2]` for example instead of `"version": 1` or `"version": 2` alone.

XXX expand, find TLS example


## Example: one-way transfer

Alice has two computers: `laptop` and `desktop`.
Alice wishes to transfer some number of files from `laptop` to `desktop`.

Alice initiates a `wormhole receive --yes` on the `desktop` machine, indicating that it should receive multiple files and not ask permission (writing each one immediately).
This program prints a code and waits for protocol setup.

Alice uses a GUI program on `laptop` that allows drag-and-drop sending of files.
In this program, she enters the code that `desktop` printed out.

Once the Dilated connection is establed, Alice can drop any number of files into the GUI application and they will be immediately written on the `desktop` without interaction.

Speaking this protocol, the `desktop` (receive-only CLI) peer sends version information:

```json
{
    "transfer": {
        "version": 1,
        "mode": "receive",
        "features": ["core"],
        "permission": "yes"
    }
}
```

The `laptop` peer then knows to not pause on its subchannels to await permission (`"permission": "yes"`).
For each file that Alice drops, the `laptop` peer:
* opens a subchannel
* sends a `FileOffer` / kind=`1` record
* immediately starts sending data (via kind=`5` records)
* closes the subchannel (when all data is sent)

On the `desktop` peer, the program patiently waits for subchannels to open.
When a subchannel opens, it:
* reads the first record and finds a `FileOffer` and opens a local file for writing
* reads subsequent data records, writing them to the open file
* notices the subchannel close
* double-checks that the corrent number of payload bytes were received
   * XXX: return a checksum ack? (this might be more in line with Waterken principals so the sending side knows to delete state relating to this file ... but arguably with Dilation it "knows" that file made it?)
* closes the file

When the GUI application finishes (e.g. Alice closes it) the mailbox is closed.
The `desktop` peer notices this and exits.


## Example: multi-directional transfer session

Alice and Bob are on a video-call together.
They are collaborating and wish to share at least one file.

Both open a GUI wormhole application.
Alice opens hers first, clicking "connect" to generate a code.
She tells Bob the code, and he enters it in his GUI.

A Dilated channel is established, and both GUIs indicate they are ready to receive and/or send files.

As Alice drops files into her GUI, Bob's side waits for confirmation from Bob.
Several files could be in this state.
Whenever Bob clicks "accept" on a file, his client answers with an `OfferAccept` message and Alice's client starts sending data records (the content of the file).
Whenever Bob clicks "reject", his client answesr with an `OfferReject` and Alice's client closes the subchannel.
XXX what if Bob is bored and clicks "cancel" on a file?

Alice and Bob may exchange several files at different times, with either Alice or Bob being the sender.
As they wrap up the call, Bob closes his GUI client which closes the mailbox (and Dilated connection).
Alice's client sees the mailbox close.
Alice's GUI tells her that Bob is done and finishes the session; she can no longer drop or add files.