import { useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { BookmarkCheck, Clock, FileText, FolderOpen, Globe, X } from "lucide-react";
import {
  getPdfFileName,
  getRecentPdfs,
  getWebpageDisplayName,
  removeRecentPdf,
  type RecentPdf,
} from "@/lib/recent-pdfs";
import * as commands from "@/lib/tauri-commands";
import { shortcut } from "@/lib/utils";
import { usePdfStore } from "@/stores/pdf-store";
import { Button } from "@/components/ui/Button";
import type { WebLibraryEntry } from "@/types";

export function WelcomeScreen() {
  const openFile = usePdfStore((s) => s.openFile);
  const openFiles = usePdfStore((s) => s.openFiles);
  const openUrl = usePdfStore((s) => s.openUrl);
  const isLoading = usePdfStore((s) => s.isLoading);
  const error = usePdfStore((s) => s.error);
  const [recentPdfs, setRecentPdfs] = useState(getRecentPdfs);
  const [savedPages, setSavedPages] = useState<WebLibraryEntry[]>([]);
  const [urlInput, setUrlInput] = useState("");

  useEffect(() => {
    let cancelled = false;
    commands
      .listSavedWebpages()
      .then((pages) => {
        if (!cancelled) setSavedPages(pages);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  const handleOpen = async () => {
    const selected = await open({
      multiple: true,
      filters: [
        { name: "Documents", extensions: ["pdf", "vellumweb"] },
        { name: "PDF", extensions: ["pdf"] },
        { name: "Vellum Web Archive", extensions: ["vellumweb"] },
      ],
    });
    if (!selected) return;
    await openFiles(Array.isArray(selected) ? selected : [selected]);
  };

  const handleOpenUrl = async () => {
    const value = urlInput.trim();
    if (!value) return;
    setUrlInput("");
    await openUrl(value);
  };

  const handleRecentOpen = async (entry: RecentPdf) => {
    if (entry.kind === "web") {
      await openUrl(entry.pdf_path);
    } else {
      await openFile(entry.pdf_path);
    }
  };

  const handleRemoveRecent = (path: string) => {
    setRecentPdfs(removeRecentPdf(path));
  };

  const handleRemoveSavedPage = async (url: string) => {
    setSavedPages((pages) => pages.filter((page) => page.url !== url));
    await commands.removeSavedWebpage(url).catch(() => {});
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

        {/* Add a webpage */}
        <div className="mt-4 flex w-full max-w-md items-center gap-2">
          <div className="flex h-10 flex-1 items-center gap-2 rounded-lg border border-border bg-surface px-3 shadow-soft">
            <Globe size={15} className="flex-shrink-0 text-muted-foreground" />
            <input
              type="text"
              className="h-full flex-1 bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground"
              placeholder="Or read a webpage — paste an article URL"
              value={urlInput}
              onChange={(e) => setUrlInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void handleOpenUrl();
              }}
              disabled={isLoading}
            />
          </div>
          <Button onClick={() => void handleOpenUrl()} disabled={isLoading || !urlInput.trim()}>
            Open
          </Button>
        </div>

        {error && (
          <p className="mt-5 max-w-md rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-center text-sm text-destructive">
            {error}
          </p>
        )}

        {/* Saved webpages */}
        {savedPages.length > 0 && (
          <section className="mt-12 w-full">
            <h2 className="mb-2 flex items-center gap-1.5 px-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              <BookmarkCheck size={13} />
              Saved pages
            </h2>
            <div className="overflow-hidden rounded-xl border border-border bg-surface shadow-soft">
              {savedPages.map((page) => {
                const displayName = getWebpageDisplayName(page.url);
                const displayTitle = page.title?.trim() || displayName;

                return (
                  <div
                    key={page.url}
                    className="group flex items-center border-b border-border last:border-b-0 transition-colors hover:bg-accent"
                  >
                    <button
                      className="focus-ring flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left disabled:opacity-50"
                      onClick={() => void openUrl(page.url)}
                      disabled={isLoading}
                      title={page.url}
                    >
                      <span className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg border border-border bg-muted text-muted-foreground transition-colors group-hover:border-border-strong group-hover:text-primary">
                        <Globe size={17} strokeWidth={1.75} />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-foreground">
                          {displayTitle}
                        </span>
                        <span className="block truncate text-xs text-muted-foreground">
                          {displayName}
                          {page.has_snapshot ? " · available offline" : ""}
                        </span>
                      </span>
                    </button>
                    <button
                      className="focus-ring mr-2 flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-md text-muted-foreground opacity-0 transition hover:bg-muted hover:text-destructive focus-visible:opacity-100 group-hover:opacity-100"
                      onClick={() => void handleRemoveSavedPage(page.url)}
                      title="Remove from saved pages"
                      aria-label={`Remove ${displayTitle} from saved pages`}
                    >
                      <X size={15} />
                    </button>
                  </div>
                );
              })}
            </div>
          </section>
        )}

        {/* Recently opened */}
        {recentPdfs.length > 0 && (
          <section className="mt-12 w-full">
            <h2 className="mb-2 flex items-center gap-1.5 px-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              <Clock size={13} />
              Recently opened
            </h2>
            <div className="overflow-hidden rounded-xl border border-border bg-surface shadow-soft">
              {recentPdfs.map((entry) => {
                const isWeb = entry.kind === "web";
                const fileName = isWeb
                  ? getWebpageDisplayName(entry.pdf_path)
                  : getPdfFileName(entry.pdf_path);
                const displayTitle = entry.title?.trim() || fileName;

                return (
                  <div
                    key={entry.pdf_path}
                    className="group flex items-center border-b border-border last:border-b-0 transition-colors hover:bg-accent"
                  >
                    <button
                      className="focus-ring flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left disabled:opacity-50"
                      onClick={() => void handleRecentOpen(entry)}
                      disabled={isLoading}
                      title={entry.pdf_path}
                    >
                      <span className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg border border-border bg-muted text-muted-foreground transition-colors group-hover:border-border-strong group-hover:text-primary">
                        {isWeb ? (
                          <Globe size={17} strokeWidth={1.75} />
                        ) : (
                          <FileText size={17} strokeWidth={1.75} />
                        )}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-foreground">
                          {displayTitle}
                        </span>
                        <span className="block truncate text-xs text-muted-foreground">
                          {displayTitle !== fileName && `${fileName} · `}
                          {!isWeb && entry.page_count
                            ? `${entry.page_count} ${entry.page_count === 1 ? "page" : "pages"} · `
                            : ""}
                          {formatOpenedDate(entry.opened_at)}
                        </span>
                      </span>
                    </button>
                    <button
                      className="focus-ring mr-2 flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-md text-muted-foreground opacity-0 transition hover:bg-muted hover:text-destructive focus-visible:opacity-100 group-hover:opacity-100"
                      onClick={() => handleRemoveRecent(entry.pdf_path)}
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
