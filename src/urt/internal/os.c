#pragma attribute(push, nothrow, nogc)

#if defined(__linux)
# define _DEFAULT_SOURCE
# include <errno.h>
# include <sys/socket.h>
# include <sys/un.h>
# include <sys/uio.h>
# include <netinet/in.h>
# include <netinet/ip.h>
# include <netinet/tcp.h>
# include <netdb.h>
# include <unistd.h>
# include <poll.h>
# include <fcntl.h>
# include <sys/ioctl.h>

// EWOULDBLOCK is #define EWOULDBLOCK EAGAIN on Linux — ImportC cannot resolve
// chained macros, so re-define as a plain integer.
# undef EWOULDBLOCK
# define EWOULDBLOCK 11   /* same as EAGAIN on Linux */
#endif
