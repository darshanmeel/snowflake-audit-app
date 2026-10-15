// Copy-to-clipboard pieces: one useCopy hook behind the fix "Copy" button, the fix block and the page "Copy link".
import React from "react";

// Copies text (or what getText returns at click time) and reports "copied" for a moment.
export function useCopy(getText: () => string): [boolean, (e?: React.MouseEvent) => void] {
  const [copied, setCopied] = React.useState(false);
  const copy = (e?: React.MouseEvent) => {
    if (e) { e.preventDefault(); e.stopPropagation(); }
    try {
      const clip = window.navigator && window.navigator.clipboard;
      if (clip && clip.writeText) {
        clip.writeText(getText()).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1200); }).catch(() => {});
      }
    } catch (err) { /* clipboard unavailable here: the button does nothing */ }
  };
  return [copied, copy];
}

export function FixCopyButton({ text, className = "copy-link-btn", label = "Copy" }: { text: string; className?: string; label?: string }) {
  const [copied, copy] = useCopy(() => text);
  return <button type="button" className={className} title="Copy this fix to the clipboard" onClick={copy}>{copied ? "Copied" : label}</button>;
}

// "The fix" with its Copy button: the same block in every drawer that shows a fix.
export function FixSection({ text, title = "The fix" }: { text: string; title?: string }) {
  return (
    <div className="dr-section">
      <div className="fx-head">
        <div className="dr-eyebrow">{title}</div>
        <FixCopyButton text={text} />
      </div>
      <pre className="dr-fix">{text}</pre>
    </div>
  );
}

// Copies the address as it is now: the hash already holds the tab, filters and whatever is open.
export function PageCopyLink({ className = "topbar-btn print-page-btn" }: { className?: string }) {
  const [copied, copy] = useCopy(() => window.location.href);
  return (
    <button type="button" className={className} onClick={copy} title="Copy a link to this exact view: page, filters and what is open">
      {copied ? "Link copied" : "Copy link"}
    </button>
  );
}
