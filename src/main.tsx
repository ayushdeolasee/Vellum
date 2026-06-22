import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ErrorBoundary } from "./components/ErrorBoundary";
import App from "./App";
import { initTheme } from "./stores/theme-store";
import "./index.css";
import "katex/dist/katex.min.css";

// Apply the saved light/dark theme before the first paint to avoid a flash.
initTheme();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary
      fallback={(error: Error) => (
        <div className="flex h-screen w-screen items-center justify-center bg-background">
          <div className="flex flex-col items-center gap-4 text-center">
            <p className="text-lg font-semibold text-destructive">
              Application crashed
            </p>
            <p className="max-w-md text-sm text-muted-foreground">
              {error.message}
            </p>
            <pre className="max-h-48 max-w-lg overflow-auto rounded bg-muted p-3 text-left text-xs">
              {error.stack}
            </pre>
            <button
              className="rounded-md border bg-background px-4 py-2 text-sm hover:bg-accent"
              onClick={() => window.location.reload()}
            >
              Reload app
            </button>
          </div>
        </div>
      )}
    >
      <App />
    </ErrorBoundary>
  </StrictMode>,
);
