# File-Transfer Protocol

The `bin/wormhole` tool uses a Wormhole to establish a connection, then speaks a file-transfer -specific protocol over that Wormhole to decide how to transfer the data.
This application-layer protocol is described here.

All application-level messages are dictionaries, which are JSON-encoded and UTF-8 encoded before being handed to `wormhole.send` (which then encrypts them before sending through the rendezvous server to the peer).

## Sender

`wormhole send` has two main modes: file/directory (which requires a non-wormhole Transit connection), or text (which does not).

If the sender is doing files or directories, its first message contains just a `transit` key, whose value is a dictionary with `abilities-v1` and `hints-v1` keys.
These are given to the Transit object, described below.

Then it sends a message with an `offer` key.
The offer contains exactly one of:

* `message`: the text message, for text-mode
* `file`: for file-mode, a dict with:
    * `filename`
    * `filesize`
* `directory`: for directory-mode, a dict with:
    * `mode`: the compression mode, currently always `zipfile/deflated`
    * `dirname`
    * `zipsize`: integer, size of the transmitted data in bytes
    * `numbytes`: integer, estimated total size of the uncompressed directory
    * `numfiles`: integer, number of files+directories being sent

The sender runs a loop where it waits for similar dictionary-shaped messages
from the recipient, and processes them. It reacts to the following keys:

* `error`: use the value to throw a TransferError and terminates
* `transit`: use the value to build the Transit instance
* `answer`:
    * if `message_ack: "ok"` is in the value (we're in text-mode), then exit with success
    * if `file_ack: "ok"` in the value (and we're in file/directory mode), then
      wait for Transit to connect, then send the file through Transit, then wait
      for an ack (via Transit), then exit

~~The sender can handle all of these keys in the same message, or spaced out over multiple ones.~~ **This is strongly discouraged!** *Probably no implementation supports receiving multiple messages in one, and no one sends multiple at once.* ~~It will ignore any keys it doesn't recognize, and will completely ignore messages that don't contain any recognized key.~~ *As all capabilities are explained during version negotiation, every sender knows what keys are supported by the other side. No unsupported values should be transferred.* The only constraint is that the message containing `message_ack` or `file_ack` is the last one: it will stop looking for wormhole messages at that point (the
wormhole connection may be closed after the ack).

## Recipient

`wormhole receive` is used for both file/directory-mode and text-mode: it
learns which is being used from the `offer` message.

The recipient enters a loop where it processes the following keys from each
received message:

* `error`: if present in any message, the recipient raises TransferError
(with the value) and exits immediately (before processing any other keys)
* `transit`: the value is used to build the Transit instance
* `offer`: parse the offer:
    * `message`: accept the message and terminate
    * `file`: connect a Transit instance, wait for it to deliver the indicated
    number of bytes, then write them to the target filename
    * `directory`: as with `file`, but unzip the bytes into the target directory

## Transit

See [transit](./transit.md) for some general documentation. The transit protocol does not specify how the data for finding each other is transferred. This is the job of the application level protocol (thus, here):

The file-transfer application uses `transit` messages to convey these
abilities and hints from one Transit object to the other. After updating the
Transit objects, it then asks the Transit object to connect, whereupon
Transit will try to connect to all the hints that it can, and will use the
first one that succeeds.

The `transit` message mentioned above is encoded following this schema:

```json
{
    "transit": {
        "abilities-v1": [ … ],
        "hints-v1": [ … ]
    }
}
```

The `abilities-v1` and `hints-v1` entries follow the canonical encoding described
in the transit protocol.

The file-transfer application, when actually sending file/directory data,
may close the Wormhole as soon as it has enough information to begin opening
the Transit connection. The final ack of the received data is sent through
the Transit object, as a UTF-8-encoded JSON-encoded dictionary with `ack: ok`
and `sha256: HEXHEX` containing the hash of the received data.

## Future Extensions

* "command mode": establish the connection, *then* figure out what we want to
  use it for, allowing multiple files to be exchanged, in either direction.
  This is to support a GUI that lets you open the wormhole, then drop files
  into it on either end.
* some Transit messages being sent early, so ports and Onion services can be
  spun up earlier, to reduce overall waiting time
* transit messages being sent in multiple phases: maybe the transit
  connection can progress while waiting for the user to confirm the transfer

The hope is that by sending everything in dictionaries and multiple messages,
there will be enough wiggle room to make these extensions in a
backwards-compatible way. For example, to add "command mode" while allowing
the fancy new (as yet unwritten) GUI client to interoperate with
old-fashioned one-file-only CLI clients, we need the GUI tool to send an "I'm
capable of command mode" in the VERSION message, and look for it in the
received VERSION. If it isn't present, it will either expect to see an offer
(if the other side is sending), or nothing (if it is waiting to receive), and
can explain the situation to the user accordingly. It might show a locked set
of bars over the wormhole graphic to mean "cannot send", or a "waiting to
send them a file" overlay for send-only.
