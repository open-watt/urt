module urt.driver.bk7231;

public import urt.driver.bk7231.irq;
public import urt.driver.bk7231.timer;
public import urt.driver.bk7231.uart;

import urt.driver.bk7231.irq : irq_enable;
import urt.driver.uart : UartConfig;

@nogc nothrow:

// Called before .data is materialised and may only use rodata and its arguments.
extern(C) bool unpack_ram()
{
    import urt.zip : uncompress;

    const(ubyte)* src = &_tdata_load;
    size_t available = cast(size_t)&_flash_end - cast(size_t)src;
    size_t length = cast(size_t)&_data_end - cast(size_t)&_tdata_start;
    size_t output_length = void;
    return uncompress(src[0 .. available], (&_tdata_start)[0 .. length], output_length) && output_length == length;
}

extern(C) void sys_init()
{
    install_exception_vectors();
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    uart_hw_init(0, UartConfig.init);
    set_printf_port(1);

    bk_misc_init_start_type();
    driver_init();
    bk_misc_check_start_type();
    func_init_basic();

    timer_hw_init();
    irq_enable();
}

private:

extern(C) extern __gshared ubyte _tdata_load, _tdata_start, _data_end, _flash_end;
extern(C) extern const ubyte __eh_frame_start;

ubyte[48] __eh_frame_object;

extern(C)
{
    void __register_frame_info(const void*, void*);
    void do_irq();
    void do_fiq();
    void do_swi();
    void do_undefined();
    void do_pabort();
    void do_dabort();
    void do_reserved();
    void set_printf_port(ubyte port);
    void bk_misc_init_start_type();
    void bk_misc_check_start_type();
    uint driver_init();
    uint func_init_basic();
}

void install_exception_vectors()
{
    alias Handler = extern(C) void function() nothrow @nogc;
    auto slot = cast(Handler*)cast(size_t)0x0040_0000;
    slot[0] = &do_irq;
    slot[1] = &do_fiq;
    slot[2] = &do_swi;
    slot[3] = &do_undefined;
    slot[4] = &do_pabort;
    slot[5] = &do_dabort;
    slot[6] = &do_reserved;
}
