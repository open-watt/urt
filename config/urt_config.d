module urt_config;

import urt.mem.page : PageClass;

// smallest first
static immutable PageClass[2] page_classes = [PageClass(352, 8, 4), PageClass(1632, 4, 2)];
