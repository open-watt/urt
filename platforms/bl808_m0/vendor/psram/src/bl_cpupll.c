#include <bl808_glb.h>

/* D0 runs from the CPU PLL, which boot2 leaves on the 380 MHz table; the C906 is rated for 480. */
void bl_cpupll_480m(void)
{
    GLB_Power_Off_WAC_PLL(GLB_WAC_PLL_CPUPLL);
    GLB_WAC_PLL_Ref_Clk_Sel(GLB_WAC_PLL_CPUPLL, GLB_PLL_REFCLK_XTAL);
    GLB_Power_On_WAC_PLL(GLB_WAC_PLL_CPUPLL, &cpuPllCfg_480M[GLB_XTAL_40M], 1);
}
