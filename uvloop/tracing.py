import abc

class Span(abc.ABC):

    @abc.abstractmethod
    def set_tag(self, key, value):
        """Tag the span with an arbitrary key and value."""

    @abc.abstractmethod
    def finish(self, finish_time=None):
        """Indicate that the work represented by this span
        has been completed or terminated."""

    @abc.abstractproperty
    def is_finished(self):
        """Return True if the current span is already finished."""


class Tracer(abc.ABC):

    @abc.abstractmethod
    def start_span(self, name, parent_span):
        """Start a new Span with a specific name. The parent of the span
        will be also passed as a paramter."""
