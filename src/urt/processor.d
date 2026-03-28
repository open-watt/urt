module urt.processor;

enum Endian : byte
{
    Native = -1, // specifies the native/working endian
    Little = 0,
    Big = 1
}

version (LittleEndian)
{
    enum LittleEndian = true;
    enum BigEndian = false;
    enum Endian proc_endian = Endian.Little;
}
else
{
    enum LittleEndian = false;
    enum BigEndian = true;
    enum Endian proc_endian = Endian.Big;
}

version (X86_64)
{
    version = Intel;
    enum string ProcessorFamily = "x86_64";
    enum string ProcessorName = "x86_64";
}
else version (X86)
{
    version = Intel;
    enum string ProcessorFamily = "x86";
    enum string ProcessorName = "x86";
}
else version (AArch64)
{
    enum string ProcessorFamily = "ARM64";
    version (LDC)
        enum string ProcessorName = __traits(targetCPU);
    else
        enum string ProcessorName = "aarch64";
}
else version (ARM)
{
    enum string ProcessorFamily = "ARM";
    enum string ProcessorName = __traits(targetCPU);

    struct ProcFeaturesT
    {
        bool crc = __traits(targetHasFeature, "crc");                                   // Enable support for CRC instructions.
        bool crypto = __traits(targetHasFeature, "crypto");                             // Enable support for Cryptography extensions.
        bool d32 = __traits(targetHasFeature, "d32");                                   // Extend FP to 32 double registers.
        bool dotprod = __traits(targetHasFeature, "dotprod");                           // Enable support for dot product instructions.
        bool fuse_aes = __traits(targetHasFeature, "fuse-aes");                         // CPU fuses AES crypto operations.
        bool fp64 = __traits(targetHasFeature, "fp64");                                 // Floating point unit supports double precision.
        bool neon = __traits(targetHasFeature, "neon");                                 // Enable NEON instructions.
        bool neon_fpmovs = __traits(targetHasFeature, "neon-fpmovs");                   // Convert VMOVSR, VMOVRS, VMOVS to NEON.
        bool no_branch_predictor = __traits(targetHasFeature, "no-branch-predictor");   // Has no branch predictor.
        bool perfmon = __traits(targetHasFeature, "perfmon");                           // Enable support for Performance Monitor extensions.
        bool sha2 = __traits(targetHasFeature, "sha2");                                 // Enable SHA1 and SHA256 support.
        bool strict_align = __traits(targetHasFeature, "strict-align");                 // Disallow all unaligned memory access.
        bool thumb = __traits(targetHasFeature, "thumb-mode");                          // Thumb mode.
        bool thumb2 = __traits(targetHasFeature, "thumb2");                             // Enable Thumb2 instructions.
        bool v4t = __traits(targetHasFeature, "v4t");                                   // Support ARM v4T instructions.
        bool v5t = __traits(targetHasFeature, "v5t");                                   // Support ARM v5T instructions.
        bool v5te = __traits(targetHasFeature, "v5te");                                 // Support ARM v5TE, v5TEj, and v5TExp instructions.
        bool v6 = __traits(targetHasFeature, "v6");                                     // Support ARM v6 instructions.
        bool v6k = __traits(targetHasFeature, "v6k");                                   // Support ARM v6k instructions.
        bool v6m = __traits(targetHasFeature, "v6m");                                   // Support ARM v6M instructions.
        bool v6t2 = __traits(targetHasFeature, "v6t2");                                 // Support ARM v6t2 instructions.
        bool v7 = __traits(targetHasFeature, "v7");                                     // Support ARM v7 instructions.
        bool v7clrex = __traits(targetHasFeature, "v7clrex");                           // Has v7 clrex instruction.
        bool v8 = __traits(targetHasFeature, "v8");                                     // Support ARM v8 instructions.
        bool vfp2 = __traits(targetHasFeature, "vfp2");                                 // Enable VFP2 instructions.
        bool vfp2sp = __traits(targetHasFeature, "vfp2sp");                             // Enable VFP2 instructions with no double precision.
        bool vfp3 = __traits(targetHasFeature, "vfp3");                                 // Enable VFP3 instructions.
        bool vfp3d16 = __traits(targetHasFeature, "vfp3d16");                           // Enable VFP3 instructions with only 16 d-registers.
        bool vfp3d16sp = __traits(targetHasFeature, "vfp3d16sp");                       // Enable VFP3 instructions with only 16 d-registers and no double precision.
        bool vfp3sp = __traits(targetHasFeature, "vfp3sp");                             // Enable VFP3 instructions with no double precision.
        bool vfp4 = __traits(targetHasFeature, "vfp4");                                 // Enable VFP4 instructions.
        bool vfp4d16 = __traits(targetHasFeature, "vfp4d16");                           // Enable VFP4 instructions with only 16 d-registers.
        bool vfp4d16sp = __traits(targetHasFeature, "vfp4d16sp");                       // Enable VFP4 instructions with only 16 d-registers and no double precision.
        bool vfp4sp = __traits(targetHasFeature, "vfp4sp");                             // Enable VFP4 instructions with no double precision.
        bool zcz = __traits(targetHasFeature, "zcz");                                   // Has zero-cycle zeroing instructions.
    }
    enum ProcFeatures = ProcFeaturesT();
}
else version (RISCV64)
{
    enum string ProcessorFamily = "RISCV64";

    // Synthesize ISA string: "RV64I" + single-letter extensions in canonical order
    enum string ProcessorName = "RV64I"
        ~ (ProcFeatures.m ? "M" : "")
        ~ (ProcFeatures.a ? "A" : "")
        ~ (ProcFeatures.f ? "F" : "")
        ~ (ProcFeatures.d ? "D" : "")
        ~ (ProcFeatures.c ? "C" : "")
        ~ (ProcFeatures.v ? "V" : "")
        ~ (ProcFeatures.h ? "H" : "")
        ~ (ProcFeatures.xtheadba ? " (T-Head)" : "");

    struct ProcFeaturesT
    {
        // Standard extensions
        bool a = __traits(targetHasFeature, "a");             // Atomic instructions
        bool c = __traits(targetHasFeature, "c");             // Compressed instructions
        bool d = __traits(targetHasFeature, "d");             // Double-precision float
        bool f = __traits(targetHasFeature, "f");             // Single-precision float
        bool h = __traits(targetHasFeature, "h");             // Hypervisor
        bool m = __traits(targetHasFeature, "m");             // Integer multiply/divide
        bool v = __traits(targetHasFeature, "v");             // Vector extension (RVV 1.0)
        // Bit manipulation
        bool zba = __traits(targetHasFeature, "zba");         // Address generation
        bool zbb = __traits(targetHasFeature, "zbb");         // Basic bit manipulation
        bool zbs = __traits(targetHasFeature, "zbs");         // Single-bit instructions
        // System
        bool zicsr = __traits(targetHasFeature, "zicsr");     // CSR instructions
        bool zifencei = __traits(targetHasFeature, "zifencei"); // Instruction-fetch fence
        // T-Head vendor extensions (BL808 C906, etc.)
        bool xtheadba = __traits(targetHasFeature, "xtheadba");           // Address calculation
        bool xtheadbb = __traits(targetHasFeature, "xtheadbb");           // Basic bit manipulation
        bool xtheadbs = __traits(targetHasFeature, "xtheadbs");           // Single-bit instructions
        bool xtheadcmo = __traits(targetHasFeature, "xtheadcmo");         // Cache management
        bool xtheadcondmov = __traits(targetHasFeature, "xtheadcondmov"); // Conditional move
        bool xtheadmac = __traits(targetHasFeature, "xtheadmac");         // Multiply-accumulate
        bool xtheadmemidx = __traits(targetHasFeature, "xtheadmemidx");   // Indexed memory ops
        bool xtheadmempair = __traits(targetHasFeature, "xtheadmempair"); // Paired memory ops
        bool xtheadsync = __traits(targetHasFeature, "xtheadsync");       // Multicore sync
        bool xtheadvdot = __traits(targetHasFeature, "xtheadvdot");       // Vector dot product
    }
    enum ProcFeatures = ProcFeaturesT();
}
else version (RISCV32)
{
    enum string ProcessorFamily = "RISCV";

    // Synthesize ISA string: "RV32I" or "RV32E" + extensions
    enum string ProcessorName = "RV32"
        ~ (ProcFeatures.e ? 'E' : 'I')
        ~ (ProcFeatures.m ? "M" : "")
        ~ (ProcFeatures.a ? "A" : "")
        ~ (ProcFeatures.f ? "F" : "")
        ~ (ProcFeatures.d ? "D" : "")
        ~ (ProcFeatures.c ? "C" : "")
        ~ (ProcFeatures.v ? "V" : "");

    struct ProcFeaturesT
    {
        // Standard extensions
        bool e = __traits(targetHasFeature, "e");             // RV32E: 16 registers only
        bool a = __traits(targetHasFeature, "a");             // Atomic instructions
        bool c = __traits(targetHasFeature, "c");             // Compressed instructions
        bool d = __traits(targetHasFeature, "d");             // Double-precision float
        bool f = __traits(targetHasFeature, "f");             // Single-precision float
        bool m = __traits(targetHasFeature, "m");             // Integer multiply/divide
        bool v = __traits(targetHasFeature, "v");             // Vector extension (RVV 1.0)
        // Bit manipulation
        bool zba = __traits(targetHasFeature, "zba");         // Address generation
        bool zbb = __traits(targetHasFeature, "zbb");         // Basic bit manipulation
        bool zbs = __traits(targetHasFeature, "zbs");         // Single-bit instructions
        // System
        bool zicsr = __traits(targetHasFeature, "zicsr");     // CSR instructions
        bool zifencei = __traits(targetHasFeature, "zifencei"); // Instruction-fetch fence
    }
    enum ProcFeatures = ProcFeaturesT();
}
else version (Xtensa)
{
    enum string ProcessorFamily = "Xtensa";

    // Synthesize name from key features
    enum string ProcessorName = "Xtensa"
        ~ (ProcFeatures.windowed ? " Windowed" : " Call0")
        ~ (ProcFeatures.fp ? (ProcFeatures.dfpaccel ? " DP" : " SP") : "")
        ~ (ProcFeatures.mac16 ? " MAC16" : "");

    struct ProcFeaturesT
    {
        // Core ISA options
        bool density = __traits(targetHasFeature, "density");       // Density (16-bit) instructions
        bool loop = __traits(targetHasFeature, "loop");             // Zero-overhead loops
        bool windowed = __traits(targetHasFeature, "windowed");     // Windowed registers (vs call0 ABI)
        bool boolean_ = __traits(targetHasFeature, "bool");         // Boolean registers
        bool sext = __traits(targetHasFeature, "sext");             // Sign extend instruction
        bool nsa = __traits(targetHasFeature, "nsa");               // Normalization shift amount
        bool clamps = __traits(targetHasFeature, "clamps");         // Clamp signed
        bool minmax = __traits(targetHasFeature, "minmax");         // Min/max instructions
        // Multiply/divide
        bool mul16 = __traits(targetHasFeature, "mul16");           // 16-bit multiply
        bool mul32 = __traits(targetHasFeature, "mul32");           // 32-bit multiply
        bool mul32high = __traits(targetHasFeature, "mul32high");   // 32-bit multiply high
        bool div32 = __traits(targetHasFeature, "div32");           // 32-bit divide
        bool mac16 = __traits(targetHasFeature, "mac16");           // 16-bit MAC (ESP32 LX6)
        // Floating point
        bool fp = __traits(targetHasFeature, "fp");                 // Single-precision float
        bool dfpaccel = __traits(targetHasFeature, "dfpaccel");     // Double-precision FP acceleration
        // System
        bool exception_ = __traits(targetHasFeature, "exception"); // Exception handling
        bool interrupt = __traits(targetHasFeature, "interrupt");   // Interrupt handling
        bool highpriinterrupts = __traits(targetHasFeature, "highpriinterrupts"); // High-priority interrupts
        bool debug_ = __traits(targetHasFeature, "debug");         // Debug support
        bool threadptr = __traits(targetHasFeature, "threadptr");   // Thread pointer register
        bool coprocessor = __traits(targetHasFeature, "coprocessor"); // Coprocessor interface
    }
    enum ProcFeatures = ProcFeaturesT();
}
else
    static assert(0, "Unsupported processor");

version (X86)
    enum SupportUnalignedLoadStore = true;
else version (X86_64)
    enum SupportUnalignedLoadStore = true;
else version (AArch64)
    enum SupportUnalignedLoadStore = true;
else version (ARM)
{
    enum SupportUnalignedLoadStore = !ProcFeatures.strict_align;
}
else version (RISCV64)
{
    enum SupportUnalignedLoadStore = __traits(targetHasFeature, "unaligned-scalar-mem");
}
else version (RISCV32)
{
    enum SupportUnalignedLoadStore = __traits(targetHasFeature, "unaligned-scalar-mem");
}
else
{
    // No arch-level feature flag available (Xtensa, MIPS, etc.)
    // Platforms that support unaligned access set -d-version=SupportUnaligned in Makefile
    // (e.g., ESP32-S3 Xtensa LX7 has hardware unaligned load/store)
    version (SupportUnaligned)
        enum SupportUnalignedLoadStore = true;
    else
        enum SupportUnalignedLoadStore = false;
}

// Different arch may define this differently...
// question is; is it worth a branch to avoid a redundant store?
enum bool BranchMoreExpensiveThanStore = false;
