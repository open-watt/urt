module urt.mem;

// TODO: remove these public imports, because this is pulled by object.d!
public import urt.lifetime : emplace, moveEmplace, forward, move;
public import urt.mem.alloc;
public import urt.mem.allocator;

// GDC's frontend ignores URT's object.d shadow for wchar_t and pulls in its
// own bundled druntime header path; pick wchar_t up explicitly there.
version (GNU)
    import core.stdc.stddef : wchar_t;

nothrow @nogc:


version (LDC)
    pragma(LDC_alloca) void* alloca(size_t size) pure @safe;
else
    extern(C) void* alloca(size_t size) pure @trusted;

extern(C)
{
nothrow @nogc:

    void* memcpy(void* dest, const void* src, size_t n) pure;
    void* memmove(void* dest, const void* src, size_t n) pure;
    void* memset(void* s, int c, size_t n) pure;
    void* memzero(void* s, size_t n) pure => memset(s, 0, n);
    int memcmp(const void *s1, const void *s2, size_t n) pure;

    size_t strlen(const char* s) pure;
    int strcmp(const char* s1, const char* s2) pure;
    char* strcpy(char* dest, const char* src) pure;
    char* strcat(char* dest, const char* src);

    size_t wcslen(const wchar_t* s) pure;
//    wchar_t* wcscpy(wchar_t* dest, const wchar_t* src) pure;
//    wchar_t* wcscat(wchar_t* dest, const wchar_t* src);
//    wchar_t* wcsncpy(wchar_t* dest, const wchar_t* src, size_t n) pure;
//    wchar_t* wcsncat(wchar_t* dest, const wchar_t* src, size_t n);
}

T debug_alloc(T = void)() pure @trusted
    if (is(T == class))
{
    static T gc_alloc(size_t size) pure nothrow => new T;
    return (cast(T function(size_t) pure nothrow @nogc)&gc_alloc)(size);
}
T* debug_alloc(T = void)() pure @trusted
    if (!is(T == class))
{
    static T* gc_alloc(size_t size) pure nothrow => new T;
    return (cast(T* function(size_t) pure nothrow @nogc)&gc_alloc)(size);
}
T[] debug_alloc(T = void)(size_t size) pure @trusted
{
    static T[] gc_alloc(size_t size) pure nothrow => new T[size];
    return (cast(T[] function(size_t) pure nothrow @nogc)&gc_alloc)(size);
}


private:

version(DigitalMars)
{
    // DMD lowers alloca(n) calls to __alloca(n)
    extern(C) void* __alloca(int nbytes)
    {
        version (D_InlineAsm_X86)
        {
            asm nothrow @nogc
            {
                naked                   ;
                mov     EDX,ECX         ;
                mov     EAX,4[ESP]      ; // get nbytes
                push    EBX             ;
                push    EDI             ;
                push    ESI             ;

                add     EAX,15          ;
                and     EAX,0xFFFFFFF0  ; // round up to 16 byte boundary
                jnz     Abegin          ;
                mov     EAX,16          ; // minimum allocation is 16
            Abegin:
                mov     ESI,EAX         ; // ESI = nbytes
                neg     EAX             ;
                add     EAX,ESP         ; // EAX is now what the new ESP will be.
                jae     Aoverflow       ;
            }
            version (Win32)
            {
                asm nothrow @nogc
                {
                    // Touch guard pages to commit stack memory
                    mov     ECX,EAX         ;
                    mov     EBX,ESI         ;
                L1:
                    test    [ECX+EBX],EBX   ;
                    sub     EBX,0x1000      ;
                    jae     L1              ;
                    test    [ECX],EBX       ;
                }
            }
            asm nothrow @nogc
            {
                mov     ECX,EBP         ;
                sub     ECX,ESP         ;
                sub     ECX,[EDX]       ;
                add     [EDX],ESI       ;
                mov     ESP,EAX         ;
                add     EAX,ECX         ;
                mov     EDI,ESP         ;
                add     ESI,ESP         ;
                shr     ECX,2           ;
                rep                     ;
                movsd                   ;
                jmp     done            ;

            Aoverflow:
                xor     EAX,EAX         ;

            done:
                pop     ESI             ;
                pop     EDI             ;
                pop     EBX             ;
                ret                     ;
            }
        }
        else version (D_InlineAsm_X86_64)
        {
            version (Win64)
            {
                asm nothrow @nogc
                {
                    naked                   ;
                    push    RBX             ;
                    push    RDI             ;
                    push    RSI             ;
                    mov     RAX,RCX         ;
                    add     RAX,15          ;
                    and     AL,0xF0         ;
                    test    RAX,RAX         ;
                    jnz     Abegin          ;
                    mov     RAX,16          ;
                Abegin:
                    mov     RSI,RAX         ;
                    neg     RAX             ;
                    add     RAX,RSP         ;
                    jae     Aoverflow       ;

                    // Touch guard pages
                    mov     RCX,RAX         ;
                    mov     RBX,RSI         ;
                L1:
                    test    [RCX+RBX],RBX   ;
                    sub     RBX,0x1000      ;
                    jae     L1              ;
                    test    [RCX],RBX       ;

                    mov     RCX,RBP         ;
                    sub     RCX,RSP         ;
                    sub     RCX,[RDX]       ;
                    add     [RDX],RSI       ;
                    mov     RSP,RAX         ;
                    add     RAX,RCX         ;
                    mov     RDI,RSP         ;
                    add     RSI,RSP         ;
                    shr     RCX,3           ;
                    rep                     ;
                    movsq                   ;
                    jmp     done            ;

                Aoverflow:
                    xor     RAX,RAX         ;

                done:
                    pop     RSI             ;
                    pop     RDI             ;
                    pop     RBX             ;
                    ret                     ;
                }
            }
            else
            {
                asm nothrow @nogc
                {
                    naked                   ;
                    mov     RDX,RCX         ;
                    mov     RAX,RDI         ;
                    add     RAX,15          ;
                    and     AL,0xF0         ;
                    test    RAX,RAX         ;
                    jnz     Abegin          ;
                    mov     RAX,16          ;
                Abegin:
                    mov     RSI,RAX         ;
                    neg     RAX             ;
                    add     RAX,RSP         ;
                    jae     Aoverflow       ;

                    mov     RCX,RBP         ;
                    sub     RCX,RSP         ;
                    sub     RCX,[RDX]       ;
                    add     [RDX],RSI       ;
                    mov     RSP,RAX         ;
                    add     RAX,RCX         ;
                    mov     RDI,RSP         ;
                    add     RSI,RSP         ;
                    shr     RCX,3           ;
                    rep                     ;
                    movsq                   ;
                    jmp     done            ;

                Aoverflow:
                    xor     RAX,RAX         ;

                done:
                    ret                     ;
                }
            }
        }
        else
            static assert(0, "Unsupported architecture for __alloca");
    }
}
