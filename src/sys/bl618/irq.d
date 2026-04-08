/// BL618 interrupt controller driver
///
/// BL616/BL618 uses a CLIC-style interrupt controller.
///
/// TODO: Implement from BL616 register map.
module sys.bl618.irq;

@nogc nothrow:

/// Globally disable interrupts
void irq_disable()
{
    asm @nogc nothrow
    {
        "csrc mstatus, 0x0008";  // Clear MIE
    }
}

/// Globally enable interrupts
void irq_enable()
{
    asm @nogc nothrow
    {
        "csrs mstatus, 0x0008";  // Set MIE
    }
}
