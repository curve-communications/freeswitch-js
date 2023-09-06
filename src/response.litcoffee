Response and associated API
===========================

    import EventEmitter from 'node:events'
    import { ulid } from 'ulidx'
    import {
      FreeSwitchParser
      FreeSwitchParserError
      parse_header_text
    } from './parser.litcoffee'

    async_log = (msg,af,logger) ->
      ->
        af().catch (error) ->
          logger.error "FreeSwitchResponse::async_log: #{msg}", { error }
          throw error

    class FreeSwitchError extends Error
      constructor: (res,args) ->
        super()
        @res = res
        @args = args
        return
      toString: ->
        "FreeSwitchError: #{JSON.stringify @args}"

    class FreeSwitchTimeout extends Error
      constructor: (timeout,text) ->
        super()
        @timeout = timeout
        @text = text
        return
      toString: ->
        "FreeSwitchTimeout: Timeout after #{@timeout}ms waiting for #{@text}"

    export class FreeSwitchResponse extends EventEmitter

The `FreeSwitchResponse` is bound to a single socket (dual-stream). For outbound (server) mode this would represent a single socket call from FreeSwitch.

      constructor: (socket,logger) ->
        super captureRejections: true
        @setMaxListeners 2000

        assert socket?, 'Missing socket parameter'
        assert.equal 'function', typeof socket.once, 'FreeSwitchResponse: socket.once must be a function'
        assert.equal 'function', typeof socket.on, 'FreeSwitchResponse: socket.on must be a function'
        assert.equal 'function', typeof socket.end, 'FreeSwitchResponse: socket.end must be a function'
        assert.equal 'function', typeof socket.write, 'FreeSwitchResponse: socket.write must be a function'
        assert logger?, 'Missing logger parameter'
        assert.equal 'function', typeof logger.debug, 'FreeSwitchResponse: logger.debug must be a function'
        assert.equal 'function', typeof logger.info, 'FreeSwitchResponse: logger.info must be a function'
        assert.equal 'function', typeof logger.error, 'FreeSwitchResponse: logger.error must be a function'

Uniquely identify each instance, for tracing purposes.

        @__ref = ulid()
        @__uuid = null

        @__socket = socket
        @logger = logger
        @stats =
          missing_content_type: 0n
          auth_request: 0n
          command_reply: 0n
          events: 0n
          json_parse_errors: 0n
          log_data: 0n
          disconnect: 0n
          api_responses: 0n
          rude_rejections: 0n
          unhandled: 0n

The module provides statistics in the `stats` object if it is initialized. You may use it  to collect your own call-related statistics.

Make the command responses somewhat unique. This is required since FreeSwitch doesn't provide us a way to match responses with requests.

        @on 'CHANNEL_EXECUTE_COMPLETE', (res) =>
          event_uuid = res.body['Application-UUID']
          @logger.debug 'FreeSwitchResponse: CHANNEL_EXECUTE_COMPLETE', { event_uuid }
          @emit "CHANNEL_EXECUTE_COMPLETE #{event_uuid}", res
          return

        @on 'BACKGROUND_JOB', (res) =>
          job_uuid = res.body['Job-UUID']
          @logger.debug 'FreeSwitchResponse: BACKGROUND_JOB', { job_uuid }
          @emit_later "BACKGROUND_JOB #{job_uuid}", {body:res.body._body}
          return

The parser is responsible for de-framing messages coming from FreeSwitch and splitting it into headers and a body.
We then process those in order to generate higher-level events.

        @__parser = new FreeSwitchParser @__socket, (headers,body) => @process headers, body

The object also provides a queue for operations which need to be submitted one after another on a given socket because FreeSwitch does not provide ways to map event socket requests and responses in the general case.

        @__queue = Promise.resolve null

The object also provides a mechanism to report events that might already have been triggered.

        @__later = new Map

We also must track connection close in order to prevent writing to a closed socket.

        @closed = false

        socket_once_close = =>
          @logger.debug 'FreeSwitchResponse: Socket closed', ref: @__ref
          @emit 'socket.close'
          return
        @__socket.once 'close', socket_once_close

Default handler for `error` events to prevent `Unhandled 'error' event` reports.

        socket_on_error = (err) =>
          @logger.debug 'FreeSwitchResponse: Socket Error', ref: @__ref, error: err
          @emit 'socket.error', err
          return
        @__socket.on 'error', socket_on_error

After the socket is closed or errored, this object is no longer usable.

        once_socket_star = (reason) =>
          @logger.debug 'FreeSwitchResponse: Terminate', { ref: @__ref, reason }
          if not @closed
            @closed = true
            # @__socket.resetAndDestroy()
            @__socket.end()
          @removeAllListeners()
          @__queue = Promise.resolve null
          @__later.clear()
          return

        @once 'socket.error', once_socket_star
        @once 'socket.close', once_socket_star
        @once 'socket.write', once_socket_star
        @once 'socket.end', once_socket_star

        null

      setUUID: (uuid) ->
        @__uuid = uuid
        return

      uuid: -> @__uuid
      ref: -> @__ref

      error: (res,data) ->
        @logger.error "FreeSwitchResponse: error: new FreeSwitchError", { ref: @__ref, res, data }
        throw new FreeSwitchError res, data

Event Emitter
=============

`default_event_timeout`
-----------------------

The default timeout waiting for events.

Note that this value must be longer than (for exemple) a regular call's duration, if you want to be able to catch `EXECUTE_COMPLETE` on `bridge` commands.

      default_event_timeout: 9*3600*1000 # 9 hours

`default_send_timeout`
----------------------

Formerly `command_timeout`, the timeout for a command sent via `send` when none is specified.

      default_send_timeout: 10*1000 # 10s

`default_command_timeout`
-------------------------

The timeout awaiting for a response to a `command` call.

      default_command_timeout: 1*1000 # 1s

onceAsync
---------

      ###*
      # @param {string} event
      # @param {number} timeout
      # @param {string} comment
      ###
      onceAsync: (event,timeout,comment) ->
        @logger.debug 'FreeSwitchResponse: onceAsync: awaiting', { event, comment, ref: @__ref, timeout }
        onceAsyncHandler = (resolve,reject) =>

          on_event = (args...) =>
            @logger.debug "FreeSwitchResponse: onceAsync: on_event", { event, comment, ref: @__ref }
            cleanup()
            resolve args...
            return

          on_error = (error) =>
            @logger.error "FreeSwitchResponse: onceAsync: on_error", { event, comment, ref: @__ref, error }
            cleanup()
            reject error
            return

          on_close = =>
            @logger.error "FreeSwitchResponse: onceAsync: on_close", { event, comment, ref: @__ref }
            cleanup()
            reject new Error "Socket closed (#{@__ref}) while waiting for #{event} in #{comment}"
            return

          on_end = =>
            @logger.error "FreeSwitchResponse: onceAsync: on_end", { event, comment, ref: @__ref }
            cleanup()
            reject new Error "end() called (#{@__ref}) while waiting for #{event} in #{comment}"
            return

          on_timeout = =>
            @logger.error "FreeSwitchResponse: onceAsync: on_timeout", { event, comment, ref: @__ref, timeout }
            cleanup()
            reject new FreeSwitchTimeout timeout, "(#{@__ref}) event #{event} in #{comment}"
            return

          cleanup = =>
            @removeListener event, on_event
            @removeListener 'socket.error', on_error
            @removeListener 'socket.close', on_close
            @removeListener 'socket.write', on_error
            @removeListener 'socket.end', on_end
            clearTimeout timer
            return

          @once event, on_event
          @once 'socket.error', on_error
          @once 'socket.close', on_close
          @once 'socket.write', on_error
          @once 'socket.end', on_end
          timer = setTimeout on_timeout, timeout if timeout?
          return

        new Promise onceAsyncHandler

Queueing
========

Enqueue a function that returns a Promise.
The function is only called when all previously enqueued functions-that-return-Promises are completed and their respective Promises fulfilled or rejected.

      enqueue: (f) ->
        if @closed
          return @error {}, {when:'enqueue on closed socket'}

        q = @__queue

        next = do ->
          await q
          await f()

        @__queue = next.catch -> yes
        next

Sync/Async event
================

waitAsync
---------

In some cases the event might have been emitted before we are ready to receive it.
In that case we store the data in `@__later` so that we can emit the event when the recipient is ready.

      waitAsync: (event,timeout,comment) ->

        if not @closed and @__later.has event
          v = @__later.get event
          @__later.delete event
          Promise.resolve v
        else
          @onceAsync event, timeout, "waitAsync #{comment}"

emit_later
----------

This is used for events that might trigger before we set the `once` receiver.

      emit_later: (event,data) ->
        handled = @emit event, data
        if not @closed and not handled
          @__later.set event, data
        handled

Low-level sending
=================

These methods are normally not used directly.

write
-----

Send a single command to FreeSwitch; `args` is a hash of headers sent with the command.

      write: (command,args) ->
        if @closed
          return @error {}, {when:'write on closed socket',command,args}

        writeHandler = (resolve,reject) =>
          try
            @logger.debug 'FreeSwitchResponse: write', { ref: @__ref, command, args }

            text = "#{command}\n"
            if args?
              for key, value of args when value?
                text += "#{key}: #{value}\n"
            text += "\n"

            @logger.debug 'FreeSwitchResponse: write', { ref: @__ref, text }
            @__socket.write text, 'utf8'
            resolve null

          catch error
            @logger.error 'FreeSwitchResponse: write error', { ref: @__ref, error }

Cancel any pending Promise started with `@onceAsync`, and close the connection.

            @emit 'socket.write', error

            reject error

          return

        new Promise writeHandler

send
----

A generic way of sending commands to FreeSwitch, wrapping `write` into a Promise that waits for FreeSwitch's notification that the command completed.

      ###*
      # @param {string} command
      # @param {object?} args
      # @param {number} timeout
      ###
      send: (command,args = undefined,timeout = @default_send_timeout) ->

        if @closed
          return @error {}, {when:'send on closed socket',command,args}

Typically `command/reply` will contain the status in the `Reply-Text` header while `api/response` will contain the status in the body.

        msg = "send #{command} #{JSON.stringify args}"

        sendHandler = =>
          p = @onceAsync 'freeswitch_command_reply', timeout, msg
          q = @write command, args

          [res] = await Promise.all [p,q]

          @logger.debug 'FreeSwitchResponse: send: received reply', { ref: @__ref, command, args }
          reply = res?.headers['Reply-Text']

The Promise might fail if FreeSwitch's notification indicates an error.

          if not reply?
            @logger.debug 'FreeSwitchResponse: send: no reply', { ref: @__ref, command, args }
            return @error res, {when:'no reply to command',command,args}

          if reply.match /^-/
            @logger.debug 'FreeSwitchResponse: send: failed', { @__ref, reply, command, args }
            return @error res, {when:'command reply',reply,command,args}

The promise will be fulfilled with the `{headers,body}` object provided by the parser.

          @logger.debug 'FreeSwitchResponse: send: success', { ref: @__ref, command, args }
          res

        await @enqueue async_log msg, sendHandler, @logger

end
---

Closes the socket.

      end: ->
        @logger.debug 'FreeSwitchResponse: end', ref: @__ref
        @emit 'socket.end', 'Socket close requested by application'
        return

Process data from the parser
============================

Rewrite headers as needed to work around some weirdnesses in the protocol; and assign unified event IDs to the Event Socket's Content-Types.

      process: (headers,body) ->
        @logger.debug 'FreeSwitchResponse::process', { ref: @__ref, headers, body }

        content_type = headers['Content-Type']
        if not content_type?
          @stats.missing_content_type++
          @logger.error 'FreeSwitchResponse::process: missing-content-type', { ref: @__ref, headers, body }
          @emit 'error.missing-content-type', new FreeSwitchParserError {headers, body}
          return

Notice how all our (internal) event names are lower-cased; FreeSwitch always uses full-upper-case event names.

        switch content_type

auth/request
------------

FreeSwitch sends an authentication request when a client connect to the Event Socket.
Normally caught by the client code, there is no need for your code to monitor this event.

          when 'auth/request'
            event = 'freeswitch_auth_request'
            @stats.auth_request++

command/reply
-------------

Commands trigger this type of event when they are submitted.
Normally caught by `send`, there is no need for your code to monitor this event.

          when 'command/reply'
            event = 'freeswitch_command_reply'

Apparently a bug in the response to `connect` causes FreeSwitch to send the headers in the body.

            if headers['Event-Name'] is 'CHANNEL_DATA'
              body = headers
              headers = {}
              for n in ['Content-Type','Reply-Text','Socket-Mode','Control']
                headers[n] = body[n]
                delete body[n]

            @stats.command_reply++

text/event-json
---------------

A generic event with a JSON body. We map it to its own Event-Name.

          when 'text/event-json'
            @stats.events++

            try

Strip control characters that might be emitted by FreeSwitch.

              body = body.replace /[\x00-\x1F\x7F-\x9F]/g, ''

Parse the JSON body.

              body = JSON.parse(body)

In case of error report it as an error.

            catch exception
              @logger.error 'FreeSwitchResponse: Invalid JSON', { ref: @__ref, body }
              @stats.json_parse_errors++

              @emit 'error.invalid-json', exception
              return

Otherwise trigger the proper event.

            event = body['Event-Name']

text/event-plain
----------------

Same as `text/event-json` except the body is encoded using plain text. Either way the module provides you with a parsed body (a hash/Object).

          when 'text/event-plain'
            body = parse_header_text(body)
            event = body['Event-Name']
            @stats.events++

log/data
--------

          when 'log/data'
            event = 'freeswitch_log_data'
            @stats.log_data++

text/disconnect-notice
----------------------

FreeSwitch's indication that it is disconnecting the socket.
You normally do not have to monitor this event; the `autocleanup` methods catches this event and emits either `freeswitch_disconnect` or `freeswitch_linger`, monitor those events instead.

          when 'text/disconnect-notice'
            event = 'freeswitch_disconnect_notice'
            @stats.disconnect++

api/response
------------

Triggered when an `api` message returns. Due to the inability to map those responses to requests, you might want to use `queue_api` instead of `api` for concurrent usage.
You normally do not have to monitor this event, the `api` methods catches it.

          when 'api/response'
            event = 'freeswitch_api_response'
            @stats.api_responses++

          when 'text/rude-rejection'
            event = 'freeswitch_rude_rejection'
            @stats.rude_rejections++

Others?
-------

          else

Ideally other content-types should be individually specified. In any case we provide a fallback mechanism.

            @logger.error 'FreeSwitchResponse: Unhandled Content-Type', { ref: @__ref, content_type }
            event = "freeswitch_#{content_type.replace /[^a-z]/, '_'}"
            @emit 'error.unhandled-content-type', new FreeSwitchParserError {content_type}
            @stats.unhandled++

Event content
-------------

The messages sent at the server- or client-level only contain the headers and the body, possibly modified by the above code.

        msg = {headers,body}

        @emit event, msg
        return


Channel-level commands
======================

api
---

Send an API command, see [Mod commands](http://wiki.freeswitch.org/wiki/Mod_commands) for a list.
Returns a Promise that is fulfilled as soon as FreeSwitch sends a reply. Requests are queued and each request is matched with the first-coming response, since there is no way to match between requests and responses.
Use `bgapi` if you need to make sure responses are correct, since it provides the proper semantices.

      api: (command,timeout) ->
        @logger.debug 'FreeSwitchResponse: api', { ref: @__ref, command }

        if @closed
          return @error {}, {when:'api on closed socket',command}

        msg = "api #{command}"

        apiHandler = =>
          p = @onceAsync 'freeswitch_api_response', timeout, msg
          q = @write "api #{command}"

          [res] = await Promise.all [p,q]

          @logger.debug 'FreeSwitchResponse: api: response', { ref: @__ref, command }
          reply = res?.body

The Promise might fail if FreeSwitch indicates there was an error.

          if not reply?
            @logger.debug 'FreeSwitchResponse: api: no reply', { @__ref, command }
            return @error res, {when:'no reply to api',command}

          if reply.match /^-/
            @logger.debug 'FreeSwitchResponse: api response failed', { ref: @__ref, reply, command }
            return @error res, {when:'api response',reply,command}

The Promise that will be fulfilled with `{headers,body,uuid}` from the parser; uuid is the API UUID if one is provided by FreeSwitch.

          res.uuid = (reply.match /^\+OK (\S+)/)?[1]
          res

        await @enqueue async_log msg, apiHandler, @logger

bgapi
-----

Send an API command in the background. Wraps it inside a Promise.

      bgapi: (command,timeout) ->
        @logger.debug 'FreeSwitchResponse: bgapi', { ref: @__ref, command, timeout }

        if @closed
          return @error {}, {when:'bgapi on closed socket',command}

        res = await @send "bgapi #{command}"
        error = => @error res, {when:"bgapi did not provide a Job-UUID",command}

        return error() unless res?
        reply = res.headers['Reply-Text']
        r = reply?.match(/\+OK Job-UUID: (.+)$/)?[1]
        r ?= res.headers['Job-UUID']
        return error() unless r?

        @logger.debug 'FreeSwitchResponse: bgapi retrieve', { ref: @__ref, reply_match: r }

        await @waitAsync "BACKGROUND_JOB #{r}", timeout, "bgapi #{command}"

Event reception and filtering
=============================

event_json
----------

Request that the server send us events in JSON format.
For example: `res.event_json 'HEARTBEAT'`

      event_json: (events...) ->

        @send "event json #{events.join(' ')}"

nixevents
---------

Remove the given event types from the events ACL.

      nixevent: (events...) ->

        @send "nixevent #{events.join(' ')}"

noevents
--------

Remove all events types.

      noevents: ->

        @send "noevents"

filter
------

Generic event filtering

      filter: (header,value) ->

        @send "filter #{header} #{value}"

filter_delete
-------------

Remove a filter.

      filter_delete: (header,value) ->
        if value?
          @send "filter delete #{header} #{value}"
        else
          @send "filter delete #{header}"

sendevent
---------

Send an event into the FreeSwitch event queue.

      sendevent: (event_name,args) ->

        @send "sendevent #{event_name}", args

Connection handling
===================

auth
----

Authenticate with FreeSwitch.

This normally not needed since in outbound (server) mode authentication is not required, and for inbound (client) mode the module authenticates automatically when requested.

      auth: (password)       -> @send "auth #{password}"

connect
-------

Used in server mode to start the conversation with FreeSwitch.

Normally not needed, triggered automatically by the module.

      connect: -> @send "connect"   # Outbound mode

linger
------

Used in server mode, requests FreeSwitch to not close the socket as soon as the call is over, allowing us to do some post-processing on the call (mainly, receiving call termination events).
By default, `esl` with call `exit()` for you after 4 seconds. You need to capture the `cleanup_linger` event if you want to handle things differently.

      linger: -> @send "linger"    # Outbound mode

exit
----

Send the `exit` command to the FreeSwitch socket.
FreeSwitch will respond with "+OK bye" followed by a `disconnect-notice` message, which gets translated into a `freeswitch_disconnect_notice` event internally, which in turn gets translated into either `freeswitch_disconnect` or `freeswitch_linger` depending on whether `linger` was called on the socket.
You normally do not need to call `@exit` directly. If you do, make sure you do handle any rejection.

      exit: -> @send "exit"

Event logging
=============

log
---

Enable logging on the socket, optionnally setting the log level.

      log: (level) ->
        if level?
          @send "log #{level}"
        else
          @send "log"

nolog
-----

Disable logging on the socket.

      nolog: -> @send "nolog"

Message sending
===============

sendmsg_uuid
------------

Send a command to a given UUID.

      sendmsg_uuid: (uuid,command,args) ->

        options = args ? {}
        options['call-command'] = command
        execute_text = 'sendmsg'
        if uuid?
          execute_text = "sendmsg #{uuid}"
        else if @__uuid?
          execute_text = "sendmsg #{@__uuid}"
        res = @send execute_text, options
        @logger.debug 'FreeSwitchResponse: sendmsg_uuid', { ref: @__ref, uuid, command, args, res }
        res

sendmsg
-------

Send Message, assuming server/outbound ESL mode (in which case the UUID is not required).

      sendmsg: (command,args) -> @sendmsg_uuid null, command, args

Client-mode ("inbound") commands
=================================

The target UUID must be specified.


execute_uuid
------------

Execute an application for the given UUID (in client mode).

      execute_uuid: (uuid,app_name,app_arg,loops,event_uuid) ->
        options =
          'execute-app-name': app_name
          'execute-app-arg':  app_arg
          loops: if loops? then loops else undefined
          'Event-UUID': if event_uuid? then event_uuid else undefined
        res = @sendmsg_uuid uuid, 'execute', options
        @logger.debug 'FreeSwitchResponse: execute_uuid', { ref: @__ref, uuid, app_name, app_arg, loops, event_uuid, res }
        res

TODO: Support the alternate format (with no `execute-app-arg` header but instead a `text/plain` body containing the argument).

command_uuid
------------

Execute an application synchronously. Return a Promise.

      command_uuid: (uuid,app_name,app_arg,timeout = @default_command_timeout) ->
        app_arg ?= ''
        event_uuid = ulid()
        event = "CHANNEL_EXECUTE_COMPLETE #{event_uuid}"

The Promise is only fulfilled when the command has completed.

        p = @onceAsync event, timeout, "uuid #{uuid} #{app_name} #{app_arg}"
        q = @execute_uuid uuid,app_name,app_arg,null,event_uuid
        [res] = await Promise.all [p,q]
        @logger.debug 'FreeSwitchResponse: command_uuid', { ref: @__ref, uuid, app_name, app_arg, timeout, event_uuid, res }
        res

hangup_uuid
-----------

Hangup the call referenced by the given UUID with an optional (FreeSwitch) cause code.

      hangup_uuid: (uuid,hangup_cause) ->
        hangup_cause ?= 'NORMAL_UNSPECIFIED'
        options =
          'hangup-cause': hangup_cause
        @sendmsg_uuid uuid, 'hangup', options

unicast_uuid
------------

Forwards the media to and from a given socket.

Arguments:
- `local-ip`
- `local-port`
- `remote-ip`
- `remote-port`
- `transport` (`tcp` or `udp`)
- `flags: "native"` (optional: do not transcode to/from L16 audio)

      unicast_uuid: (uuid,args) ->
        @sendmsg_uuid uuid, 'unicast', args

nomedia_uuid
------------

Not implemented yet (TODO).

Server-mode commands
====================

In server (outbound) mode, the target UUID is always our (own) call UUID, so it does not need to be specified.

execute
-------

Execute an application for the current UUID (in server/outbound mode)

      execute: (app_name,app_arg)  -> @execute_uuid null, app_name, app_arg

command
-------

      command: (app_name,app_arg)  -> @command_uuid null, app_name, app_arg


hangup
------

      hangup: (hangup_cause)       -> @hangup_uuid  null, hangup_cause

unicast
-------

      unicast: (args)              -> @unicast_uuid null, args

TODO: `nomedia`

Cleanup at end of call
======================

auto_cleanup
------------

Clean-up at the end of the connection.
Automatically called by the client and server.

      auto_cleanup: ->

        @once 'freeswitch_disconnect_notice', (res) =>
          @logger.debug 'FreeSwitchResponse: auto_cleanup: Received ESL disconnection notice', { ref: @__ref, res }
          switch res.headers['Content-Disposition']
            when 'linger'
              @logger.debug 'FreeSwitchResponse: Sending freeswitch_linger', ref: @__ref
              @emit 'freeswitch_linger'
            when 'disconnect'
              @logger.debug 'FreeSwitchResponse: Sending freeswitch_disconnect', ref: @__ref
              @emit 'freeswitch_disconnect'
            else # Header might be absent?
              @logger.debug 'FreeSwitchResponse: Sending freeswitch_disconnect', ref: @__ref
              @emit 'freeswitch_disconnect'
          return

### Linger

In linger mode you may intercept the event `cleanup_linger` to do further processing. However you are responsible for calling `exit()`. If you do not do it, the calls will leak. (Make sure you also `catch` any errors on exit: `exit().catch(...)`.)

The default behavior in linger mode is to disconnect the socket after 4 seconds, giving you some time to capture events.

        linger_delay = 4000

        once_freeswitch_linger = () =>
          @logger.debug 'FreeSwitchResponse: auto_cleanup/linger', ref: @__ref
          if @emit 'cleanup_linger'
            @logger.debug 'FreeSwitchResponse: auto_cleanup/linger: cleanup_linger processed, make sure you call exit()', ref: @__ref
          else
            @logger.debug "FreeSwitchResponse: auto_cleanup/linger: exit() in #{linger_delay}ms", ref: @__ref
            setTimeout =>
              @logger.debug 'FreeSwitchResponse: auto_cleanup/linger: exit()', ref: @__ref
              @exit().catch -> yes
              return
            , linger_delay
          return

        @once 'freeswitch_linger', once_freeswitch_linger

### Disconnect

On disconnect (no linger) mode, you may intercept the event `cleanup_disconnect` to do further processing. However you are responsible for calling `end()` in order to close the socket.

Normal behavior on disconnect is to close the socket with `end()`.

        once_freeswitch_disconnect = () =>
          @logger.debug 'FreeSwitchResponse: auto_cleanup/disconnect', ref: @__ref
          if @emit 'cleanup_disconnect'
            @logger.debug 'FreeSwitchResponse: auto_cleanup/disconnect: cleanup_disconnect processed, make sure you call end()', ref: @__ref
          else
            setTimeout =>
              @logger.debug 'FreeSwitchResponse: auto_cleanup/disconnect: end()', ref: @__ref
              @end()
            , 100
          return

        @once 'freeswitch_disconnect', once_freeswitch_disconnect

        return null

Toolbox
=======

    import assert from 'node:assert'
