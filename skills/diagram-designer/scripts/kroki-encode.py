#!/usr/bin/env python3
"""Encode diagram DSL source to kroki.io URL-safe base64 segment.

Reads the DSL source from stdin and prints the encoded segment to
stdout. Used by the diagram-designer skill to construct kroki.io
preview URLs of the form:

    https://kroki.io/<diagram_type>/<output_format>/<encoded>

The encoding kroki expects is zlib-compressed (deflate + zlib header +
adler32 checksum) then base64 url-safe (with `+`/`/` replaced by
`-`/`_` and trailing `=` padding stripped). Plain URL percent-encoding
will not work.
"""

import sys
import zlib
import base64


def main() -> None:
    src = sys.stdin.buffer.read()
    compressed = zlib.compress(src, 9)
    encoded = base64.urlsafe_b64encode(compressed).rstrip(b"=")
    sys.stdout.write(encoded.decode("ascii"))


if __name__ == "__main__":
    main()
