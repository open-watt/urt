// PWM channels. A channel runs on the chip's PWM block where one is free, or in software from the
// periodic timer where the chip has none spare. A hardware_required channel must get a PWM block, and
// takes one from a flexible holder by moving that holder to software; a Pwm handle survives the move.
module urt.driver.pwm;

import urt.driver.gpio : GpioLine, gpio_count, num_gpio;
import urt.driver.timer : has_timer_compare;
import urt.result : InternalResult, Result;

version (Espressif)
    public import urt.driver.esp32.pwm;
else version (RP2350)
    public import urt.driver.rp2350.pwm;
else version (STM32)
    public import urt.driver.stm32.pwm;
else version (BL808)
    public import urt.driver.bl_common.pwm;
else
    enum uint num_hw_pwm = 0;

enum bool has_soft_pwm = has_timer_compare && num_gpio > 0;

static if (has_soft_pwm)
    import urt.driver.soft_pwm;
else
    enum uint num_soft_pwm = 0;

enum uint num_pwm = num_hw_pwm + num_soft_pwm;

nothrow @nogc:


struct PwmConfig
{
    GpioLine output;
    uint frequency;
    uint period; // Duty values range from zero through period.
    uint initial_duty;
    bool inverted;
    bool hardware_required; // exact frequency and timing; software is not acceptable
}

struct Pwm
{
    ubyte slot = ubyte.max;
}

bool is_open(ref const Pwm pwm) pure
{
    return pwm.slot != ubyte.max;
}

bool is_hardware(ref const Pwm pwm)
{
    static if (num_pwm == 0)
        return false;
    else
        return pwm.is_open && _slots[pwm.slot].hardware;
}

// Claims exactly this PWM block, as a required channel.
Result pwm_open(ref Pwm pwm, ubyte port, ref const PwmConfig config)
{
    static if (num_hw_pwm == 0)
        return InternalResult.unsupported;
    else
    {
        if (pwm.is_open)
            return InternalResult.already_exists;
        if (port >= num_hw_pwm || !valid(config))
            return InternalResult.invalid_parameter;
        ubyte s = new_slot(config);
        if (s == none)
            return InternalResult.failed;
        _slots[s].config.hardware_required = true;
        Result result = claim_required(s, port);
        if (!result)
        {
            _slots[s].open = false;
            return result;
        }
        pwm.slot = s;
        return Result.success;
    }
}

// Takes a free PWM block the line can reach, then software, then a PWM block held by a flexible channel.
Result pwm_acquire(ref Pwm pwm, ref const PwmConfig config)
{
    static if (num_pwm == 0)
        return InternalResult.unsupported;
    else
    {
        if (pwm.is_open)
            return InternalResult.already_exists;
        if (!valid(config))
            return InternalResult.invalid_parameter;
        ubyte s = new_slot(config);
        if (s == none)
            return InternalResult.failed;
        foreach_reverse (port; 0 .. num_hw_pwm)
        {
            if (_hw_owner[port] == none && reaches(port, config.output) && claim_hardware(s, port))
            {
                pwm.slot = s;
                return Result.success;
            }
        }
        if (!config.hardware_required && claim_software(s))
        {
            pwm.slot = s;
            return Result.success;
        }
        if (config.hardware_required)
        {
            foreach_reverse (port; 0 .. num_hw_pwm)
            {
                if (reaches(port, config.output) && claim_required(s, port))
                {
                    pwm.slot = s;
                    return Result.success;
                }
            }
        }
        _slots[s].open = false;
        return InternalResult.failed;
    }
}

Result pwm_set_duty(ref Pwm pwm, uint duty)
{
    static if (num_pwm == 0)
        return InternalResult.unsupported;
    else
    {
        if (!pwm.is_open || duty > _slots[pwm.slot].config.period)
            return InternalResult.invalid_parameter;
        Slot* slot = &_slots[pwm.slot];
        slot.duty = duty;
        static if (num_hw_pwm != 0)
        {
            if (slot.hardware)
                return pwm_hw_set_duty(slot.port, duty);
        }
        static if (num_soft_pwm != 0)
            soft_set_duty(slot.port, duty);
        return Result.success;
    }
}

void pwm_close(ref Pwm pwm)
{
    static if (num_pwm != 0)
    {
        if (pwm.is_open)
        {
            release(pwm.slot);
            _slots[pwm.slot].open = false;
        }
    }
    pwm = Pwm();
}


private:

enum ubyte none = ubyte.max;

struct Slot
{
    PwmConfig config;
    uint duty;
    ubyte port;
    bool open;
    bool hardware;
}

static if (num_pwm != 0)
{
    __gshared Slot[num_pwm] _slots;
    __gshared ubyte[num_hw_pwm] _hw_owner = none;
    __gshared ubyte[num_soft_pwm] _soft_owner = none;

    bool valid(ref const PwmConfig config)
        => config.output.line != uint.max && config.frequency != 0 && config.period != 0 && config.initial_duty <= config.period;

    ubyte new_slot(ref const PwmConfig config)
    {
        foreach (i, ref slot; _slots)
        {
            if (slot.open)
                continue;
            slot = Slot(config, config.initial_duty, 0, true, false);
            return cast(ubyte)i;
        }
        return none;
    }

    bool reaches(uint port, GpioLine line)
    {
        static if (__traits(compiles, pwm_hw_reaches(port, line)))
            return pwm_hw_reaches(port, line);
        else
            return true;
    }

    Result claim_hardware(ubyte s, uint port)
    {
        static if (num_hw_pwm == 0)
            return InternalResult.unsupported;
        else
        {
            PwmConfig config = _slots[s].config;
            config.initial_duty = _slots[s].duty;
            Result result = pwm_hw_open(port, config);
            if (!result)
                return result;
            _hw_owner[port] = s;
            _slots[s].port = cast(ubyte)port;
            _slots[s].hardware = true;
            return Result.success;
        }
    }

    bool claim_software(ubyte s)
    {
        static if (num_soft_pwm == 0)
            return false;
        else
        {
            const(PwmConfig)* config = &_slots[s].config;
            if (config.output.chip != 0 || config.output.line >= gpio_count() || config.period > soft_pwm_max_period)
                return false;
            foreach (i, ref owner; _soft_owner)
            {
                if (owner != none)
                    continue;
                const(Slot)* slot = &_slots[s];
                soft_open(cast(uint)i, slot.config.output.line, slot.config.period, slot.duty, slot.config.inverted);
                owner = s;
                _slots[s].port = cast(ubyte)i;
                _slots[s].hardware = false;
                return true;
            }
            return false;
        }
    }

    void release(ubyte s)
    {
        Slot* slot = &_slots[s];
        static if (num_hw_pwm != 0)
        {
            if (slot.hardware)
            {
                pwm_hw_close(slot.port);
                _hw_owner[slot.port] = none;
                return;
            }
        }
        static if (num_soft_pwm != 0)
        {
            soft_close(slot.port);
            _soft_owner[slot.port] = none;
        }
    }

    // A required channel's PWM block, freed of flexible holders: of the block itself, and of any block that
    // shares its timing and so stops it opening.
    Result claim_required(ubyte s, uint port)
    {
        Result result = make_room(port);
        if (!result)
            return result;
        result = claim_hardware(s, port);
        static if (__traits(compiles, pwm_hw_shares(0u, 0u)))
        {
            foreach (other; 0 .. num_hw_pwm)
            {
                if (result)
                    break;
                if (other == port || _hw_owner[other] == none || !pwm_hw_shares(port, other) || !make_room(other))
                    continue;
                result = claim_hardware(s, port);
            }
        }
        return result;
    }

    // Frees a PWM block by moving its flexible holder to software.
    Result make_room(uint port)
    {
        static if (num_hw_pwm == 0)
            return InternalResult.unsupported;
        else
        {
            ubyte holder = _hw_owner[port];
            if (holder == none)
                return Result.success;
            if (_slots[holder].config.hardware_required)
                return InternalResult.already_exists;
            static if (num_soft_pwm == 0)
                return InternalResult.already_exists;
            else
            {
                bool spare;
                foreach (owner; _soft_owner)
                    spare |= owner == none;
                if (!spare)
                    return InternalResult.already_exists;
                release(holder);
                claim_software(holder);
                return Result.success;
            }
        }
    }
}


unittest
{
    Pwm pwm;
    assert(!pwm.is_open);
    assert(!pwm.is_hardware);
}
