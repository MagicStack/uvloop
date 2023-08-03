#ifndef UVLOOP_FORK_HANDLER_H_
#define UVLOOP_FORK_HANDLER_H_

volatile uint64_t MAIN_THREAD_ID = 0;
volatile int8_t MAIN_THREAD_ID_SET = 0;

#ifdef _WIN32
/* No fork() in windows - so ignore this */
#define PyOS_BeforeFork() 0
#define PyOS_AfterFork_Parent() 0
#define PyOS_AfterFork_Child() 0
#define pthread_atfork(prepare, parent, child) 0
#include <winsock2.h>
#else
#include <pthread.h>
#include <sys/socket.h>

#endif

typedef void (*OnForkHandler)(void);

OnForkHandler __forkHandler = NULL;

/* Auxiliary function to call global fork handler if defined.

Note: Fork handler needs to be in C (not cython) otherwise it would require
GIL to be present, but some forks can exec non-python processes.
*/
void handleAtFork(void) {
    // Reset the MAIN_THREAD_ID on fork, because the main thread ID is not
    // always the same after fork, especially when forked from within a thread.
    MAIN_THREAD_ID_SET = 0;

    if (__forkHandler != NULL) {
        __forkHandler();
    }
}


void setForkHandler(OnForkHandler handler)
{
    __forkHandler = handler;
}


void resetForkHandler(void)
{
    __forkHandler = NULL;
}

void setMainThreadID(uint64_t id) {
    MAIN_THREAD_ID = id;
    MAIN_THREAD_ID_SET = 1;
}
#endif
