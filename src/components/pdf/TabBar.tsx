import { open } from "@tauri-apps/plugin-dialog";
import { FileText, Plus, X } from "lucide-react";
import { usePdfStore } from "@/stores/pdf-store";
import { IconButton } from "@/components/ui/IconButton";
import { Wordmark } from "@/components/ui/Wordmark";
import { cn } from "@/lib/utils";

function tabLabel(title: string | null, pdfPath: string): string {
  if (title?.trim()) return title;
  return pdfPath.split(/[\\/]/).pop()?.replace(/\.pdf$/i, "") ?? "Untitled";
}

export function TabBar() {
  const tabs = usePdfStore((s) => s.tabs);
  const activeTabId = usePdfStore((s) => s.activeTabId);
  const activateTab = usePdfStore((s) => s.activateTab);
  const closeTab = usePdfStore((s) => s.closeTab);
  const openFiles = usePdfStore((s) => s.openFiles);

  const handleOpen = async () => {
    const selected = await open({
      multiple: true,
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (!selected) return;
    await openFiles(Array.isArray(selected) ? selected : [selected]);
  };

  return (
    <div className="flex h-10 flex-shrink-0 items-center gap-2 border-b bg-background pl-3 pr-2">
      <Wordmark className="flex-shrink-0" />

      {tabs.length > 0 && (
        <div className="h-5 w-px flex-shrink-0 bg-border" aria-hidden />
      )}

      <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto py-1">
        {tabs.map((tab) => {
          const isActive = tab.id === activeTabId;
          const label = tabLabel(tab.document.title, tab.document.pdf_path);

          return (
            <div
              key={tab.id}
              className={cn(
                "group flex h-7 min-w-32 max-w-56 flex-shrink-0 items-center rounded-md text-xs transition-colors",
                isActive
                  ? "bg-surface text-foreground shadow-soft ring-1 ring-border-strong"
                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
              onMouseDown={(event) => {
                if (event.button === 1) {
                  event.preventDefault();
                  void closeTab(tab.id);
                }
              }}
              title={tab.document.pdf_path}
            >
              <button
                className="flex min-w-0 flex-1 items-center gap-2 py-2 pl-2.5 text-left"
                onClick={() => activateTab(tab.id)}
              >
                <FileText
                  size={13}
                  className={cn(
                    "flex-shrink-0",
                    isActive ? "text-primary" : "text-muted-foreground",
                  )}
                />
                <span className="min-w-0 flex-1 truncate">{label}</span>
              </button>
              <button
                className="focus-ring mr-1 flex h-5 w-5 flex-shrink-0 items-center justify-center rounded text-muted-foreground opacity-0 transition hover:bg-accent hover:text-foreground focus-visible:opacity-100 group-hover:opacity-100"
                onClick={(event) => {
                  event.stopPropagation();
                  void closeTab(tab.id);
                }}
                aria-label={`Close ${label}`}
              >
                <X size={12} />
              </button>
            </div>
          );
        })}
      </div>

      <IconButton
        onClick={handleOpen}
        title="Open PDF in new tab"
        aria-label="Open PDF in new tab"
      >
        <Plus size={16} />
      </IconButton>
    </div>
  );
}
