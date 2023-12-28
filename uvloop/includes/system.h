#ifndef UVLOOP_SYSTEM_H_
#define UVLOOP_SYSTEM_H_
#if defined(_WIN32) || defined(MS_WINDOWS) || defined(_MSC_VER)
#include "Winsock2.h"
#include "ws2def.h"
#include "includes/fork_handler.h"
#else
#include "arpa/inet.h"
#include "sys/socket.h"
#include "sys/un.h"
#include "unistd.h"
#include "pthread.h"
#endif
#endif


