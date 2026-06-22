import { forwardRef, type ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

type Variant = "ghost" | "primary" | "active";
type Size = "sm" | "md";

interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
}

const sizeClasses: Record<Size, string> = {
  sm: "h-7 w-7",
  md: "h-8 w-8",
};

const variantClasses: Record<Variant, string> = {
  ghost:
    "text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-30",
  active: "bg-primary text-primary-foreground hover:bg-primary-hover",
  primary:
    "bg-primary text-primary-foreground hover:bg-primary-hover disabled:opacity-50",
};

/**
 * A single, consistent square icon button used across the chrome. Every
 * toolbar/tab/panel control should reach for this so sizing, radius, hover,
 * and focus behavior stay identical everywhere.
 */
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(
  function IconButton(
    { variant = "ghost", size = "sm", className, type = "button", ...props },
    ref,
  ) {
    return (
      <button
        ref={ref}
        type={type}
        className={cn(
          "focus-ring inline-flex flex-shrink-0 items-center justify-center rounded-md transition-colors",
          sizeClasses[size],
          variantClasses[variant],
          className,
        )}
        {...props}
      />
    );
  },
);
