import { useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { Clock, FileText, FolderOpen, X } from "lucide-react";
import {
  getPdfFileName,
  getRecentPdfs,
  removeRecentPdf,
  type RecentPdf,
} from "@/lib/recent-pdfs";
import { shortcut } from "@/lib/utils";
import { usePdfStore } from "@/stores/pdf-store";
import { Button } from "@/components/ui/Button";

export function WelcomeScreen() {
  const openFile = usePdfStore((s) => s.openFile);
  const openFiles = usePdfStore((s) => s.openFiles);
  const isLoading = usePdfStore((s) => s.isLoading);
  const error = usePdfStore((s) => s.error);
  const [recentPdfs, setRecentPdfs] = useState(getRecentPdfs);

  const handleOpen = async () => {
    const selected = await open({
      multiple: true,
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (!selected) return;
    await openFiles(Array.isArray(selected) ? selected : [selected]);
  };

  const handleRecentOpen = async (pdf: RecentPdf) => {
    await openFile(pdf.pdf_path);
  };

  const handleRemoveRecent = (path: string) => {
    setRecentPdfs(removeRecentPdf(path));
  };

  return (
    <div className="flex h-full min-h-0 flex-col items-center overflow-auto bg-well px-6 py-16">
      <div className="flex w-full max-w-2xl flex-col items-center">
        {/* Hero */}
        <div className="relative mb-3 flex h-16 w-16 items-center justify-center rounded-2xl border border-border-strong bg-surface shadow-soft">
          <FileText size={30} className="text-primary" strokeWidth={1.5} />
        </div>
        <h1 className="font-serif text-4xl font-semibold tracking-tight text-foreground">
          Vellum<span className="text-primary">.</span>
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          A quiet place to read, annotate, and think alongside your documents.
        </p>

        <div className="mt-7 flex items-center gap-3">
          <Button size="lg" onClick={handleOpen} disabled={isLoading}>
            <FolderOpen size={18} />
            {isLoading ? "Opening…" : "Open a PDF"}
          </Button>
          <span className="text-xs text-muted-foreground">
            or press{" "}
            <kbd className="rounded border border-border-strong bg-surface px-1.5 py-0.5 font-mono text-[11px] text-foreground shadow-soft">
              {shortcut("O")}
            </kbd>
          </span>
        </div>

        {error && (
          <p className="mt-5 max-w-md rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-center text-sm text-destructive">
            {error}
          </p>
        )}

        {/* Recently opened */}
        {recentPdfs.length > 0 && (
          <section className="mt-12 w-full">
            <h2 className="mb-2 flex items-center gap-1.5 px-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              <Clock size={13} />
              Recently opened
            </h2>
            <div className="overflow-hidden rounded-xl border border-border bg-surface shadow-soft">
              {recentPdfs.map((pdf) => {
                const fileName = getPdfFileName(pdf.pdf_path);
                const displayTitle = pdf.title?.trim() || fileName;

                return (
                  <div
                    key={pdf.pdf_path}
                    className="group flex items-center border-b border-border last:border-b-0 transition-colors hover:bg-accent"
                  >
                    <button
                      className="focus-ring flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left disabled:opacity-50"
                      onClick={() => handleRecentOpen(pdf)}
                      disabled={isLoading}
                      title={pdf.pdf_path}
                    >
                      <span className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg border border-border bg-muted text-muted-foreground transition-colors group-hover:border-border-strong group-hover:text-primary">
                        <FileText size={17} strokeWidth={1.75} />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-foreground">
                          {displayTitle}
                        </span>
                        <span className="block truncate text-xs text-muted-foreground">
                          {displayTitle !== fileName && `${fileName} · `}
                          {pdf.page_count
                            ? `${pdf.page_count} ${pdf.page_count === 1 ? "page" : "pages"} · `
                            : ""}
                          {formatOpenedDate(pdf.opened_at)}
                        </span>
                      </span>
                    </button>
                    <button
                      className="focus-ring mr-2 flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-md text-muted-foreground opacity-0 transition hover:bg-muted hover:text-destructive focus-visible:opacity-100 group-hover:opacity-100"
                      onClick={() => handleRemoveRecent(pdf.pdf_path)}
                      title={`Remove ${fileName} from recent files`}
                      aria-label={`Remove ${fileName} from recent files`}
                    >
                      <X size={15} />
                    </button>
                  </div>
                );
              })}
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

function formatOpenedDate(openedAt: string): string {
  const date = new Date(openedAt);
  if (Number.isNaN(date.getTime())) return "Recently opened";

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
  }).format(date);
}
