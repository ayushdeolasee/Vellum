import { cn } from "@/lib/utils";

interface WordmarkProps {
  className?: string;
}

/**
 * The Vellum wordmark. Set in the serif display face — the one place the
 * "parchment" identity is allowed to speak loudly. The dotless, raised period
 * acts as a small manuscript flourish.
 */
export function Wordmark({ className }: WordmarkProps) {
  return (
    <span
      className={cn(
        "font-serif text-[15px] font-semibold tracking-tight text-foreground select-none",
        className,
      )}
    >
      Vellum
      <span className="text-primary">.</span>
    </span>
  );
}
