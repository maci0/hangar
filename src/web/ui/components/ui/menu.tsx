import { cva, type VariantProps } from "class-variance-authority";
import type { ComponentChildren, ComponentProps } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { cn } from "@/lib/cn";

/** Gap between the anchor and the menu, and the closest the menu gets to a viewport edge. */
const MENU_GAP = 6;
const VIEWPORT_MARGIN = 8;
const ENABLED_ITEM = '[role="menuitem"]:not([disabled])';
const NAV_KEYS: ReadonlySet<string> = new Set(["ArrowDown", "ArrowUp", "Home", "End"]);

type Position = { readonly top: number; readonly left: number };

export type MenuProps = {
  readonly id?: string;
  readonly label: string;
  readonly open: boolean;
  /** Element the menu hangs from; a closed menu needs none. */
  readonly anchor: HTMLElement | null;
  /** `start` lines the menu's left edge up with the anchor, `end` its right edge. */
  readonly align?: "start" | "end";
  readonly class?: string;
  /** Called after an item inside the menu is clicked. */
  readonly onSelect?: () => void;
  readonly children: ComponentChildren;
};

const place = (menu: HTMLElement, anchor: HTMLElement, align: "start" | "end"): Position => {
  const box = anchor.getBoundingClientRect();
  const wanted = align === "end" ? box.right - menu.offsetWidth : box.left;
  const widest = window.innerWidth - menu.offsetWidth - VIEWPORT_MARGIN;
  return { top: box.bottom + MENU_GAP, left: Math.max(VIEWPORT_MARGIN, Math.min(wanted, widest)) };
};

const stepTarget = (key: string, current: number, count: number): number => {
  if (key === "Home") {
    return 0;
  }
  if (key === "End") {
    return count - 1;
  }
  if (key === "ArrowDown") {
    return current < 0 ? 0 : (current + 1) % count;
  }
  return current <= 0 ? count - 1 : current - 1;
};

/**
 * Popup menu (`role="menu"`) positioned under its anchor. Opening focuses the first enabled
 * item; Arrow/Home/End move focus between enabled items. Escape and outside clicks are the
 * owner's job because they need to know which trigger to hand focus back to.
 */
export const Menu = ({ id, label, open, anchor, align = "start", class: className, onSelect, children }: MenuProps) => {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<Position>({ top: 0, left: 0 });

  useLayoutEffect(() => {
    const menu = ref.current;
    if (!open || !menu || !anchor) {
      return undefined;
    }
    const reposition = () => setPosition(place(menu, anchor, align));
    reposition();
    window.addEventListener("resize", reposition);
    return () => window.removeEventListener("resize", reposition);
  }, [open, anchor, align]);

  useEffect(() => {
    if (open) {
      ref.current?.querySelector<HTMLElement>(ENABLED_ITEM)?.focus();
    }
  }, [open]);

  const onKeyDown = (event: KeyboardEvent) => {
    if (!NAV_KEYS.has(event.key) || !ref.current) {
      return;
    }
    const items = [...ref.current.querySelectorAll<HTMLElement>(ENABLED_ITEM)];
    if (items.length === 0) {
      return;
    }
    event.preventDefault();
    const focused = items.find((item) => item === event.target);
    const current = focused === undefined ? -1 : items.indexOf(focused);
    items[stepTarget(event.key, current, items.length)]?.focus();
  };

  const onClick = (event: MouseEvent) => {
    if (event.target instanceof Element && event.target.closest('[role="menuitem"]') !== null) {
      onSelect?.();
    }
  };

  return (
    <div
      ref={ref}
      id={id}
      role="menu"
      aria-label={label}
      class={cn(
        "fixed z-230 min-w-50 max-w-67.5 rounded-md border border-border bg-surface p-1 shadow-menu",
        open ? "open block animate-menu-in" : "hidden",
        className,
      )}
      style={{ top: position.top, left: position.left }}
      onKeyDown={onKeyDown}
      onClick={onClick}
    >
      {children}
    </div>
  );
};

const menuItemVariants = cva(
  "menu-item group flex min-h-6.5 w-full items-center gap-2 overflow-hidden rounded-sm border-0 bg-transparent px-2.25 py-1 text-left text-xs text-ellipsis whitespace-nowrap transition-colors -outline-offset-2 focus-visible:outline-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-45 pointer-coarse:min-h-11",
  {
    variants: {
      variant: {
        default: "text-fg hover:bg-accent-soft hover:text-accent",
        danger: "text-danger-text hover:bg-danger-soft hover:text-danger-text",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export type MenuItemProps = ComponentProps<"button"> & VariantProps<typeof menuItemVariants>;

/** Menu row. Icons inside pick up the row's hover color through `group`. */
export const MenuItem = ({ class: className, variant, ...props }: MenuItemProps) => (
  <button type="button" role="menuitem" class={cn(menuItemVariants({ variant }), className)} {...props} />
);

/** Icon class for a menu row: dim until the row is hovered, red in a danger row. */
export const menuIconClass = (danger: boolean): string =>
  cn("ico size-3.25", danger ? "text-danger-text" : "text-fg-dim group-hover:text-accent");

export const MenuSeparator = () => <div role="separator" class="mx-1.5 my-1 block h-px bg-border-soft" />;
