// Minimal termios bindings for Linux.

module urt.internal.sys.posix.termios;

version (linux):
extern(C) nothrow @nogc:

alias cc_t = ubyte;
alias speed_t = uint;
alias tcflag_t = uint;

enum NCCS = 32;

struct termios
{
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_lflag;
    tcflag_t c_cflag;
    cc_t c_line;
    cc_t[NCCS] c_cc;
    speed_t c_ispeed;
    speed_t c_ospeed;
}

// c_iflag
enum IGNBRK  = 0x01;
enum BRKINT  = 0x02;
enum PARMRK  = 0x08;
enum ISTRIP  = 0x20;
enum INLCR   = 0x40;
enum IGNCR   = 0x80;
enum ICRNL   = 0x100;
enum IXON    = 0x400;
enum IXOFF   = 0x1000;
enum IXANY   = 0x800;

// c_oflag
enum OPOST = 0x01;
enum ONLCR = 0x04;

// c_cflag
enum CSIZE   = 0x30;
enum CS5     = 0x00;
enum CS6     = 0x10;
enum CS7     = 0x20;
enum CS8     = 0x30;
enum CSTOPB  = 0x40;
enum CREAD   = 0x80;
enum PARENB  = 0x100;
enum PARODD  = 0x200;
enum CLOCAL  = 0x800;
enum CRTSCTS = 0x80000000;

// c_lflag
enum ISIG    = 0x01;
enum ICANON  = 0x02;
enum ECHO    = 0x08;
enum ECHOE   = 0x10;
enum ECHONL  = 0x40;
enum IEXTEN  = 0x8000;

// c_cc indices
enum VMIN    = 6;
enum VTIME   = 5;

// tcsetattr actions
enum TCSANOW   = 0;
enum TCSAFLUSH = 2;

// tcflush queue selectors
enum TCIFLUSH  = 0;
enum TCOFLUSH  = 1;
enum TCIOFLUSH = 2;

// baud rates
enum B0      = 0x0;
enum B50     = 0x1;
enum B75     = 0x2;
enum B110    = 0x3;
enum B134    = 0x4;
enum B150    = 0x5;
enum B200    = 0x6;
enum B300    = 0x7;
enum B600    = 0x8;
enum B1200   = 0x9;
enum B1800   = 0xA;
enum B2400   = 0xB;
enum B4800   = 0xC;
enum B9600   = 0xD;
enum B19200  = 0xE;
enum B38400  = 0xF;
enum B57600  = 0x1001;
enum B115200 = 0x1002;
enum B230400 = 0x1003;
enum B460800 = 0x1004;
enum B500000 = 0x1005;
enum B576000 = 0x1006;
enum B921600 = 0x1007;

int tcgetattr(int fd, termios* t);
int tcsetattr(int fd, int action, const termios* t);
int tcflush(int fd, int queue);
speed_t cfgetispeed(const termios* t);
speed_t cfgetospeed(const termios* t);
int cfsetispeed(termios* t, speed_t speed);
int cfsetospeed(termios* t, speed_t speed);
