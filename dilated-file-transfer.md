# Dilated File-Transfer Protocol

This version of the file-transfer protocol is a complete replacement for the original file-transfer protocol (which we now refer to as "classic").

Both sides must support and use Dilation (see `dilation-protocol.md`).

Any all-caps words ("MAY", "MUST", etc) follow RFC2119 conventions.

NOTE: there are several open questions / discussion points, some with corresponding "XXX" comments inline.


## Overview and Features

Dilated File Transfer is a flexible, session-based approach to file transfer allowing either side to offer files (or groups of files) to send.
The receiving side may accept or reject each offer.
Both sides can make and complete one or more ofers, allowing flexible UX.
Either side MAY terminate the transfer session (by closing the wormhole)
An extension mechanism allows for future (optional) features.

Metadata is included in the offers to allow the receiver to decide if they want that file (or group of files) before the transfer begins.

"Offers" generally correspond to what a user might select; a single-file offer is possible but so is a directory.
In both cases, they are treated as "an offer" even though a directory may consist of dozens or more individual files.
For directory offers, files are sent individually without dependencies on archive formats (like zip or tar).

Filenames are relative paths.
When sending individual files, this will simply be the filename portion (with no leading paths).
For a series of files in a directory (i.e. if a directory was selected to send) paths will be relative to that directory (starting with the directory itself).
(XXX see "file naming" in discussion)


## Version Negotiation

There is an existing file-transfer protocol which does not use Dilation (called "classic" in this document).
Clients supporting newer versions of file-transfer (i.e. the one in this document) SHOULD offer backwards compatibility where possible.

In the core mailbox protocol applications can indicate version information via `app_versions`.
The existing file-transfer protocol doesn't use this feature so the version information is empty (indicating "classic").
This new Dilated File Transfer MUST include version information:

```json
{
    "transfer": {
        "mode": "{send|receive|connect}",
        "features": ["core0"],
    }
}
```
Peers MUST tolerate the existence of unknown keys in the version and transfer dicts, especially (but not limited) to the presence of unknown features.```
**Rejected idea**: having a `version` number that increases.
Per RFC 9170, it can be the case that a protocol can "ossify" or lose its flexibility, including when using "highest common version" sorts of negotiation.
Multiple extension points (e.g. both "version" and "features") can cause confusion; including both was rejected after considering the question, "when would `version` be incremented instead of using a `feature`?"

The `mode` key indicates the desired mode of that peer.
It has one of three values:
* `"send"`: the peer will only send files (similar to classic transfer protocol)
* `"receive"`: the peer only receive files (the flip side of the above)
* `"connect"`: the peer will send and receive zero or more files before closing the session

Note that `send` and `receive` above will still use Dilation as all clients supporting this protocol must.
If a peer sends no version information at all, it will be using the classic protocol (and is thus using Transit and not Dilation for the peer-to-peer connection).

The `"features"` key is a list of message-formats / features understood by the peer.
This allows for existing messages to be extended, or for new message types to be added.
Peers MUST _accept_ messages for any features they list.
Peers MUST only send messages for features that exist in both their own and in the other side's list (that is, the intersection of the two features lists).
Peers MUST tolerate the existence of unknown values in the `"features"` list.

The following required features MUST be supported: `"core0"`

The following optional features MAY be supported: `"compression"` (see "Feature: Compression (optional)").

(XXX might make the Python implementation randomly add an unknown one, 10% of the time?)

See "Example of Protocol Expansion" below for discussion about adding new attributes or capabilities or evolving existing ones.


## Protocol Details

See the Dilation document for details on the Dilation setup procedure.
Once a Dilation-supporting connection is open, we will have a "control" subchannel (subchannel #0).
Either peer can also open additional subchannels.

All control-channel messages are encoded using `msgpack` (rejected idea: JSON, because it lacks integers and binary types).

Control-channel message formats are described using Python (and Haskell) pseudo-code to illustrate the exact data types involved.

All control-channel messages contain a "kind" field describing the type of message.

**Rejected idea**: Version message, because we already do version negotiation via mailbox features.

**Rejected idea**: Offer/Answer messages via the control channel: we need to open a subchannel anyway; and the subchannel-IDs are not intended to be part of the public Dilation API.


### Control Channel Messages

All control-channel messages MUST be msgpack-encoded as a list, where the first element is a String indicating the "kind".
Other elements depend on the kind.

#### Freeform Text Messages

Each side MAY send a free-form text message at any time.
These messages are of kind "message" and include a second string, the message itself.
For example, in Python objects: `["message", "This is magic!"]` or the following 24 bytes: `92 a7 6d 65 73 73 61 67  65 ae 54 68 69 73 20 69 3 20 6d 61 67 69 63 21` after msgpack encoding.

#### Session Shutdown

Each side MUST send a "done" message at some point (this is of kind "done", and has no additional arguments).
Once such a message has been sent this side MUST NOT begin any more Offers of its own nor may it send any control-channel messages.
Once both sides have done this *and* all outstanding Offers have completed (from either/both sides) the session is concluded.

A peer that has chosen mode "receive" MAY send their "done" message right away.

NOTE: if the "Ending a Session Gracefully" proposal (or something similar) lands in the core protocol, that method should instead be preferred for shutdown (see https://github.com/magic-wormhole/magic-wormhole-mailbox-server/issues/31).


Future extensions to the protocol may add additional control-channel messages.
Note that any such addition will also come with a new "feature" flag, so implementations should reject connections sending unknown control-channel messages.


### Making an Offer

Either side MAY begin any number of Offers at any time after the connection is set up.
If the other peer specified `"mode": "send"` then this peer MUST NOT make any offers.

To make an Offer the peer opens a subchannel.
All communications related to a single Offer use this one subchannel.

As a rough overview, an Offer looks like this:
* sender opens a subchannel;
* sends a FileOffer or DirectoryOffer message;
* awaits a reply;
* if the reply is Accept, the bytes are transmitted;
* the subchannel is closed.

In case the reply is Reject, the subchannel is closed.
It is the **offering** side which MUST close the connection.

Note that whenever a subchannel closes, the Dilation connection and any other subchannels remain active.

Recall from the Dilation specification that subchannels are _record_ pipes (not simple byte-streams).
That is, a subchannel transmits a series of complete (framed) messages (up to ~4GiB in size).

For this protocol, each record on the subchannl is a complete single `msgpack`-encoded message.
The single thing in the message MUST be an "array" type, and MUST start with a string indicating the "kind" of message.
Any remaining elements in the array `kind` -specific.

The following kinds of messages exist:
* `"file-offer"`: a single `FileOffer` (other fields follow in the array)
* `"directory-offer"`: a single `DirectoryOffer` (other fields follow in the array)
* `"offer-accept"`: an `OfferAccept` message
* `"offer-reject"`: an `OfferReject` message
* `"data"`: binary file data, contained in the remaining field
* `"zdata"`: (only with "compression" enabled; see that section)

(The "features" mechanism can be used to experiment with new sorts of messages, as ultimately a new feature needs to be described in this protocol document and that description may specify more "kinds" of message).

.. NOTE::

   Rejected idea: originally we used the first byte of the message to indicate its "kind", some of which were msgpack-encoded.
   Testing shows that `msgpack` Python can encode 15 gigabytes per second on a moderate laptop (Core i7 at 1.1Ghz).
   If future performance-testing indicates that skipping the `msgpack` encoding of "just file bytes" is useful for CPU or memory pressure, a future revision of the protocol could change this decision.

The first message sent on the new subchannel MUST be either `FileOffer` or `DirectoryOffer`.

To offer a single file (with message kind `"file-offer"`):

```python
@attrs.frozen
class FileOffer:
    filename: str    # unicode relative pathname
    bytes: int       # total number of bytes in the file

    def to_bytes(self):
        return msgpack.packb(["file-offer", self.filename, self.bytes])
```

To offer a directory tree of many files (with message kind `"directory-offer"`):
```python
@attrs.frozen
class DirectoryOffer:
    base: str          # unicode path segment of the root directory (i.e. what the user selected)
    size: int          # total number of bytes in _all_ files
    files: list[str]   # a list containing relative paths for each file

    def to_bytes(self):
        return msgpack.packb(["directory-offer", self.base, self.size, self.files])
```

The filenames in the `"files"` list are unicode relative paths (relative to the `"base"` from the `DirectoryOffer` and NOT including that part).
The `base` name MUST NOT include any path separators (neither forward nor backward slashes).
The filenames in `files` MAY include path separators, which MUST always be `/` (even on non-unix systems).
To be clear: any path separator MUST be a `/`.
The filenames in `files` MUST NOT include `..`.

For clarity: **any** referance to a file outside of ``base`` is a protocol error and MUST cause an immediate rejection of the entire Offer.

For example:

```python
DirectoryOffer(
    base="project",
    size: 165,
    files=["README", "src/hello.py"]
    ]
)
```

This is encoded to `msgpack` as the following 40 bytes in "hexdump" format:

```
00000000  93 af 64 69 72 65 63 74  6f 72 79 2d 6f 66 66 65  |..directory-offe|
00000010  72 cc a5 92 a6 52 45 41  44 4d 45 ac 73 72 63 2f  |r....README.src/|
00000020  68 65 6c 6c 6f 2e 70 79                           |hello.py|
00000028
```

If decoded directly back into Python, this will appear as:

```
['directory-offer', 165, ['README', 'src/hello.py']]
```

This message indicates an offer to send two files, one in `"project/README"` and the other in `"project/src/hello.py"`.
A client can consider the "base" name as suggestion, of course.
On the flip side, a privacy-conscious sending application could offer to randomize the name when sending (or at least use something other than the on-filesystem name).

Note that a UI treatment can still have a list with multiple offers in it; this protocol is spoken per-subchannel so another offer would be on a separate subchannel.

The peer MUST answer with either `OfferAccept` or `OfferReject`.
These are indicated by the "kind" of that message being `"offer-accept"` or `"offer-reject"` (see list above).

```python
@attrs.frozen
class OfferReject:
    reason: str      # unicode string describing why the offer is rejected

    def to_bytes(self):
        return msgpack.packb(["offer-reject", self.reason])
```

Accept messages are blank (that is, there are no more elements after the `"offer-accept"` kind).

```python
@attrs.frozen
class OfferAccept:
    def to_bytes(self):
        return msgpack.packb(["offer-accept"])
```

When the offering side gets an `OfferReject` message, the subchannel MUST be immediately closed (by the offering side).
The offering side SHOULD show the "reason" string to the user.

When the offering side gets an `OfferAccept` message it begins streaming the file over the already-opened subchannel.
When completed, the subchannel is closed.

That is, the offering side always initiates the open and close of the corresponding subchannel.

Messages of kind `"data"` have a single following field consisting of the binary data.
Because a single data message MUST NOT exceed 65535 (65KiB) due to Noise Protocol limits.
This means that the most actual data that may be included in a `Data` message is 65526 bytes.
Another way to say that is that the `msgpack` encoding of the `"data"` string and length of data is at most 10 bytes.

```
@attrs.frozen
class Data:
    data: bytes

    def to_bytes(self):
        return msgpack.packb(["data", self.data])
```

Applications are free to choose how to fragment the file data so long as no single message (after `msgpack` encoding) is bigger than 65535 bytes.
A good default to choose in 2024 is 16KiB (2^14 - 1 payload bytes)

When sending a `DirectoryOffer` each individual file is preceeded by a `FileOffer` message.
However the rules about "maybe wait for reply" no longer exist; that is, all file data SHOULD be immediately sent.
The receiving side MUST NOT send a reply message (`OfferReject` or `OfferAccept`) in this case.

See examples down below, after "Discussion".


## Feature: Compression (optional)

Support for this optional feature is indicated with `"compression"` in the `"features"` list.
If present, file data MUST all be compressed using ZStandard.

This introduces a new message kind: **``0x06``: compressed file data bytes**.
Using a new "kind" here helps applications avoid confusion as to what sort of payload is received.
When both peers list `"compression"` in their `"features"` then there should be no `0x05` (file data bytes) messages only `0x06` ones.

A single Offer, whether it is a FileOffer or a DirectoryOffer MUST use a single "Compression Context" for the entire offer.
One can think of this as processing all the data from a single subchannel via one compression context.
Although the DirectoryOffer wire-format uses FileOffers to dilineate different files, a single compression context MUST still be used for the entire DirectoryOffer (i.e. all files in it).
Note that only file-bytes themselves are compressed and the wire format of protocol messages remains the same whether using `"compression"` or not.

The Python implementation uses the "streaming" mode of zstandard; other implementations may make their own choices.

Although it is optional in ZStandard, clients MUST enable the ``write_content_size`` option that populates the decompressed size into the ZStandard header.
Peers MUST NOT set any "dictionary" information in the compression context.
Peers MAY choose their own compression-level; if in doubt use the ZStandard default (currently "3").
Any other ZStandard options SHOULD remain at their default value.

Implementations SHOULD send one "ZStandard Frame" in each message -- however, peers MUST deal with partial frames properly when reading data.
That is, any given `0x06` message is "the next bunch of bytes" and may be zero, one or more entire ZStandard frames.
There MUST be a ZStandard Frame boundary at the end of each file in a DirectoryOffer.

Here is partial Python code showing how a sending-side might accomplish this (with the [https://python-zstandard.readthedocs.io](python-zstandard) library)::

    # "subchannel" here is some encapsulation of the open subchannel we have
    # obtained for this Offer, with a "send_message()" member

    class MessageEncapsulator:
        def __init__(self, subchannel):
            self.subchannel = subchannel

        def write(self, data):
            message = b"0x06" + data
            self.subchannel.send_message(message)

    # dummy values, the application UX would obtain these somehow
    filesize = 1234
    fd = open("a-file", "rb")

    # compression level 3 is the default; we MUST specifify write_content_size=True though
    ctx = zstd.ZstdCompressor(level=3, write_content_size=True)
    output = MessageEncapsulator(subchannel)
    with ctx.stream_writer(output, size=filesize, write_size=19*1024) as writer:
        while True:
            data = fd.read(16*1024)
            if data:
                writer.write(data)
            else:
                break


## Discussion and Open Questions

* streaming data

Q: There is no "finished" message. Maybe there should be? (e.g. the
   receiving side sends back a hash of the file to confirm it received it
   properly?)

Q: Does "re-using" the `FileOffer` as a kind of "header" when
   streaming `DirectoryOffer` contents make sense?

A: We need _something_ to indicate the next file etc

Q: Do the limits on message size make sense? Should "65KiB" be much smaller, potentially?

A: Given that network conditions etc vary a lot, I think it makes
   sense for the _spec_ to be somewhat flexible here and "65k" doesn't
   seem very onerous for most modern devices / computers. This is also
   the Noise limit so it's not completel arbitrary.


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

As specified above, if the human selects `/home/meejah/project/src/hello.py` then it should be sent as `hello.py`.
However if they select `/home/meejah/project/` then there should be a DirectoryOffer that looks like:

```python
DirectoryOffer(
    base="project",
    size=4444,  # actually sum of all file-sizes
    files=[
        "local-network.dia",
        "traffic.pcap",
        "README",
        "src/hello.py"
    ]
)
```

The sending client UX could offer to change the base name to something else.
The receiving client could choose to "suggest" the name, or simply use it, or anything else deemed appropriate.


## Protocol Expansion Exercises

Here we present several scenarios for different kinds of protocol expansion.
The point here is to discuss the _kinds_ of expansions that might happen.
These examples here ARE NOT part of the spec and SHOULD NOT be implemented.

That said, we believe they're realistic features that _could_ make sense as future protocol expansions.


### Thumbnails

Suppose we decide to add `thumbnail: bytes` to the `Offer` messages.
It is reasonable to imagine that some clients may not make use of this feature at all (e.g. CLI programs) and so work and bandwidth can be saved by not producing and sending them.

This becomes a new `"feature"` in the protocol.
That is, the version information is upgraded to allow `"features": ["core0", "thumbnails"]`.

Peers that do not understand (or do not _want_) thumbnails do not include that in their `"features"` list.
So, according to the protocol, these peers should never receive anything related to thumbnails.
Only if both peers include `"features": ["thumbnails"]` will they receive thumbnail-related information.

The thumbnail feature itself could be implemented by expanding the `Offer` message:

```python
class Offer:
    filename: str
    bytes: int
    thumbnail: bytes  # optional; introduced in "thumbnail" feature; PNG data
```

A new peer speaking to an old peer will never see `thumbnail` in the Offers, because the old peer sent `"formats": ["core0"]` so the new peer knows not to inclue that attribute (and the old peer won't ever send it).

Two new peers speaking will both send `"formats": ["core0", "thumbnails"]` and so will both include (and know how to interpret) `"thumbnail"` attributes on `Offers`.

Additionally, a new peer that _doesn't want_ to see `"thumbnail"` data (e.g. it's a CLI client) can simply not include `"thumbnail"` in their `"formats"` list even if their protocol implementation knows about it.


### Per-Offer Permissions

It may be more efficient to have a mode that doesn't bother with the extra round-trip per offer for asking permission.

If that proved to be a useful feature, how can we add it?
(NB: an early draft of this protocol included this behavior, but it was decided to leave it as a possible future enhancement for simplicity)

This affects the state-machine / behavior of both the sender (who now has to wait more often) and the receiver (who now has to send a new message).

If both sides include a `"permissions"` in their `"features"` list, then this mode is enabled.
We could further include a `"fine-grained"` mode too, allowing asking between each and every file in a DirectoryOffer.

Each peer has an unambiguous change to behavior: they now _always_ wait for an answer message between each offer (or between each file for "fine-grained" during a DirectoryOffer).
The receiving peer _always_ sends an OfferAccept or OfferReject for each file in a DirectoryOffer (in a "fine-grained" mode).

A peer wanting an "accept all" option can choose not to bother the _human_ on each file, but MUST still answer on the wire like this.

Another way to specify and implement this behavior could be to introduce a `FineGrainedDirectoryOffer` or similar, which would only be a valid message to send when both sides have `"fine-grained"` enabled.

In any case, a newer peer that does understand `"fine-grained"` can always provide compatibility with clients that don't.
Although wasteful on bandwidth, such a peer could even simulate the user-experience by throwing away the received bytes for files the receiving human doesn't want.

An implementation with explicit state-machines would likely choose to implement the most-complicated thing that it supports -- and then, if that feature isn't enabled, it can "skip" that state.
Most of this feature actually simplifies the state-machine (skipping past any "wait for permission" state).
However, an implementation cannot simplify the state-machine (because they cannot know whether their peer will support a "do-not-ask" mode as proposed in this section).

## Removing Features

It may be desirable to actually remove features from the protocol.
As time goes on, features may be added and removed and there may come a time when a particular feature is dropped.
Implementations may want to simplify their state-machines or other code by removing support for older features.

This is fairly straightforward: they simply no longer advertise suppor for that feature.
Some care must be taken to propose new changes in cohesive, logical chunks -- that is, several features could be lumped together as a `core1` feature upgrade.
Doing it this way would make it hard to drop any individual feature.

Another consideration is whether it is a "superset" of existing features.
If substantial changes are made to the core protocol are made, these may be proposed as `core1` for example.
One must take care to state which pieces of `core0` are part of `core1` (maybe none, maybe all of them) such that support for `core0` can acutally be dropped at a future time.


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
        "mode": "receive",
        "features": ["core0"]
    }
}
```

Becase the "permission" mode is not in the default protocol, the software will still have to answer each Offer but will not bother the user (due to the `--yes` option).

For each file that Alice drops, the `laptop` peer:
* opens a subchannel
* sends a 0x01 byte plus msgpack-encoded `["file-offer", ...]` record
* waits for an answer (`["offer-accept"]`) from the `desktop` peer
* starts sending data (via kind=`0x05` records)
* closes the subchannel (when all data is sent)

On the `desktop` peer, the program waits for subchannels to open.
When a subchannel opens, it:
* reads the first record and finds a 0x01 byte, msgpack-decodes the rest to `["file-offer", "README", 1200]` indicating a 1200 byte file called "README"
* sends an 0x01 byte + msgpack-encoded `["offer-accept"]` message immediately, without asking the human
* reads subsequent data records, writing them to the open file
* notices the subchannel close
* closes the file

When the GUI application finishes (e.g. Alice closes it) the Dilation session is ended (and the mailbox is closed).
The `desktop` peer notices this and exits.

(XXX no, see "ending a session gracefully" PRs)


## Example: multi-directional transfer session

Alice and Bob are on a video-call together.
They are collaborating and wish to share at least one file.

Both open a GUI wormhole application.
Alice opens hers first, clicking "connect" to generate a code.
She tells Bob the code, and he enters it in his GUI.

A Dilated channel is established, and both GUIs indicate they are ready to receive and/or send files.

As Alice drops files into her GUI, Bob's side waits for confirmation.
Several files could be in this state.
Whenever Bob clicks "accept" on a file, his client answers with an `OfferAccept` message and Alice's client starts sending data records (the content of the file).
If Bob were to click "reject" then his client would answer with an `OfferReject` and Alice's client would close the subchannel.
XXX what if Bob is bored and clicks "cancel" on a file?

Alice and Bob may exchange several files at different times in either direction.
As they wrap up the call, Bob close his GUI client which closes the mailbox (and Dilated connection).
Alice's client sees the mailbox close.
Alice's GUI tells her that Bob is done and finishes the session; she can no longer drop or add files.
