// The netconsole, as far as the console UART can tell: it sees every byte it is given.
module urt.driver.mt7621.netcon;

nothrow @nogc:

__gshared size_t netcon_bytes;

void netcon_put(const(char)[] s)
{
    netcon_bytes += s.length;
}
