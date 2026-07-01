import { forwardRef, type ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

type Variant = "primary" | "secondary" | "ghost";
type Size = "sm" | "md" | "lg";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
}

const sizeClasses: Record<Size, string> = {
  sm: "h-7 gap-1.5 px-2.5 text-xs",
  md: "h-9 gap-2 px-3.5 text-sm",
  lg: "h-11 gap-2 px-5 text-sm",
};

const variantClasses: Record<Variant, string> = {
  primary:
    "bg-primary text-primary-foreground shadow-soft hover:bg-primary-hover disabled:opacity-50",
  secondary:
    "border border-border-strong bg-surface text-foreground hover:bg-accent disabled:opacity-50",
  ghost:
    "text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50",
};

/** A consistent text button with optional leading icon. */
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "primary", size = "md", className, type = "button", ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={cn(
        "focus-ring inline-flex items-center justify-center rounded-md font-medium transition-colors",
        sizeClasses[size],
        variantClasses[variant],
        className,
      )}
      {...props}
    />
  );
});
