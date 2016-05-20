# LICENSE: PSF.

# Copied from asyncio 3.5.2.  Remove this file when we don't need
# to support earlier versions.

cdef _set_concurrent_future_state(concurrent, source):
    """Copy state from a future to a concurrent.futures.Future."""
    assert source.done()
    if source.cancelled():
        concurrent.cancel()
    if not concurrent.set_running_or_notify_cancel():
        return
    exception = source.exception()
    if exception is not None:
        concurrent.set_exception(exception)
    else:
        result = source.result()
        concurrent.set_result(result)


cdef _copy_future_state(source, dest):
    """Internal helper to copy state from another Future.

    The other Future may be a concurrent.futures.Future.
    """
    assert source.done()
    if dest.cancelled():
        return
    assert not dest.done()
    if source.cancelled():
        dest.cancel()
    else:
        exception = source.exception()
        if exception is not None:
            dest.set_exception(exception)
        else:
            result = source.result()
            dest.set_result(result)


cdef _chain_future(source, destination):
    """Chain two futures so that when one completes, so does the other.

    The result (or exception) of source will be copied to destination.
    If destination is cancelled, source gets cancelled too.
    Compatible with both asyncio.Future and concurrent.futures.Future.
    """
    if not isinstance(source, (aio_Future, cc_Future)):
        raise TypeError('A future is required for source argument')
    if not isinstance(destination, (aio_Future, cc_Future)):
        raise TypeError('A future is required for destination argument')

    source_loop = None
    dest_loop = None

    source_type = type(source)
    dest_type = type(destination)

    if source_type is uvloop_Future:
        source_loop = (<BaseFuture>source)._loop
    elif source_type is not cc_Future and \
            isinstance(source, aio_Future):
        source_loop = source._loop

    if dest_type is uvloop_Future:
        dest_loop = (<BaseFuture>destination)._loop
    elif dest_type is not cc_Future and \
            isinstance(destination, aio_Future):
        dest_loop = destination._loop

    def _set_state(future, other):
        if isinstance(future, aio_Future):
            _copy_future_state(other, future)
        else:
            _set_concurrent_future_state(future, other)

    def _call_check_cancel(destination):
        if destination.cancelled():
            if source_loop is None or source_loop is dest_loop:
                source.cancel()
            else:
                source_loop.call_soon_threadsafe(source.cancel)

    def _call_set_state(source):
        if dest_loop is None or dest_loop is source_loop:
            _set_state(destination, source)
        else:
            dest_loop.call_soon_threadsafe(_set_state, destination, source)

    destination.add_done_callback(_call_check_cancel)
    source.add_done_callback(_call_set_state)


def _wrap_future(future, *, loop=None):
    # Don't use this function -- it's here for tests purposes only
    # and can be removed in future versions of uvloop.

    if isinstance(future, aio_Future):
        return future
    assert isinstance(future, cc_Future), \
        'concurrent.futures.Future is expected, got {!r}'.format(future)
    if loop is None:
        loop = aio_get_event_loop()
    try:
        create_future = loop.create_future
    except AttributeError:
        new_future = aio_Future(loop=loop)
    else:
        new_future = create_future()
    _chain_future(future, new_future)
    return new_future
