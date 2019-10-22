
typedef void (*OnForkHandler)();

OnForkHandler __forkHandler = NULL;

/* Auxiliary function to call global fork handler if defined.

Note: Fork handler needs to be in C (not cython) otherwise it would require
GIL to be present, but some forks can exec non-python processes.
*/
void handleAtFork() {
    if (__forkHandler != NULL) {
        __forkHandler();
    }
}
