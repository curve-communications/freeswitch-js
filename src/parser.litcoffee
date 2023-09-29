Event Socket stream parser
==========================

    import querystring from 'node:querystring'

    class FreeSwitchParserError extends Error
      constructor: (error,buffer) ->
        super JSON.stringify {error,buffer}
        @error = error
        @buffer = buffer
        return

    export class FreeSwitchParser

The Event Socket parser will parse an incoming ES stream, whether your code is acting as a client (connected to the FreeSwitch ES server) or as a server (called back by FreeSwitch due to the "socket" application command).

      constructor: (socket,@process) ->
        @body_length = 0
        @buffer = Buffer.alloc 0
        @buffer_length = 0

### Dispatch incoming data into the header or body parsers.

Capture the body as needed

        socket.on 'data', (data) =>
          if @body_length > 0
            @capture_body data
          else
            @capture_headers data
          return

For completeness provide an `on_end()` method.

        socket.once 'end', =>
          if @buffer_length > 0
            socket.emit 'warning', new FreeSwitchParserError 'Buffer is not empty at end of stream', @buffer
          return

        return

### Capture body

      capture_body: (data) ->

When capturing the body, `buffer` contains the current data (text), and `body_length` contains how many bytes are expected to be read in the body.

        @buffer_length += data.length
        @buffer = Buffer.concat [@buffer, data], @buffer_length

As long as the whole body hasn't been received, keep adding the new data into the buffer.

        if @buffer_length < @body_length
          return

Consume the body once it has been fully received.

        body = @buffer.toString 'utf8', 0, @body_length
        @buffer = @buffer.slice @body_length
        @buffer_length -= @body_length
        @body_length = 0

Process the content at each step.

        @process @headers, body
        @headers = {}

Re-parse whatever data was left after the body was fully consumed.

        @capture_headers Buffer.alloc 0
        return

### Capture headers

      capture_headers: (data) ->

Capture headers, meaning up to the first blank line.

        @buffer_length += data.length
        @buffer = Buffer.concat [@buffer, data], @buffer_length

Wait until we reach the end of the header.

        header_end = @buffer.indexOf '\n\n'
        if header_end < 0
          return

Consume the headers

        header_text = @buffer.toString 'utf8', 0, header_end
        @buffer = @buffer.slice header_end+2
        @buffer_length -= header_end+2

Parse the header lines

        @headers = parse_header_text header_text

Figure out whether a body is expected

        if @headers["Content-Length"]
          @body_length = parseInt @headers["Content-Length"], 10

Parse the body (and eventually process)

          @capture_body Buffer.alloc 0

        else

Process the (header-only) content

          @process @headers
          @headers = {}

Re-parse whatever data was left after these headers were fully consumed.

          @capture_headers Buffer.alloc 0

        return

Headers parser
==============

Event Socket framing contains headers and a body.
The header must be decoded first to learn the presence and length of the body.

    export parse_header_text = (header_text) ->

      header_lines = header_text.split '\n'
      headers = {}
      for line in header_lines
        do (line) ->
          [name,value] = line.split /: /, 2
          headers[name] = value

Decode headers: in the case of the "connect" command, the headers are all URI-encoded.

      if headers['Reply-Text']?[0] is '%'
        for name of headers
          headers[name] = querystring.unescape(headers[name] ? '')

      return headers
