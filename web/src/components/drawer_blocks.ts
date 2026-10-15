// web/src/components/drawer_blocks.ts -- a check's own detail block inside the drawer, by check id.
// Kept free of imports, so a module can register its block at load time in any import order.
import type React from "react";

export const DRAWER_BLOCKS: Record<string, React.ComponentType<any>> = {};
export function registerDrawerBlock(id: string, comp: React.ComponentType<any>) { DRAWER_BLOCKS[id] = comp; }
