import { open } from "@tauri-apps/plugin-dialog";
import { usePdfStore } from "@/stores/pdf-store";
import { FileText, FolderOpen } from "lucide-react";
import { confirmPdfImport } from "@/lib/pdf-import";

export function WelcomeScreen() {
  const { openFile, isLoading, error } = usePdfStore();

  const handleOpen = async () => {
    const selected = await open({
      multiple: false,
      filters: [
        {
          name: "Vellum / PDF",
          extensions: ["rr", "pdf"],
        },
      ],
    });
    const selectedPath = Array.isArray(selected) ? selected[0] : selected;
    if (!selectedPath || !confirmPdfImport(selectedPath)) return;
    await openFile(selectedPath);
  };

  return (
    <div className="flex h-full flex-col items-center justify-center gap-6">
      <div className="flex flex-col items-center gap-2">
        <FileText size={48} className="text-muted-foreground" />
        <h1 className="text-2xl font-semibold">Vellum</h1>
        <p className="text-sm text-muted-foreground">
          Open a PDF or .rr file to get started
        </p>
      </div>

      <button
        className="flex items-center gap-2 rounded-lg bg-primary px-6 py-3 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
        onClick={handleOpen}
        disabled={isLoading}
      >
        <FolderOpen size={18} />
        {isLoading ? "Opening..." : "Open File"}
      </button>

      {error && (
        <p className="max-w-md text-center text-sm text-destructive">
          {error}
        </p>
      )}

      <div className="mt-4 text-xs text-muted-foreground">
        <p>
          <kbd className="rounded border bg-muted px-1.5 py-0.5 font-mono">
            Ctrl+O
          </kbd>{" "}
          to open a file
        </p>
      </div>
    </div>
  );
}
