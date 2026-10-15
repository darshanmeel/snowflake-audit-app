// The window label the shell last computed ("16–22 Sep 2026"), for tiles that say "No data for this in ...".
let auditRange: string | null = null;
export function setAuditRange(label: string | null | undefined): void { auditRange = label || null; }
export function getAuditRange(): string | null { return auditRange; }
