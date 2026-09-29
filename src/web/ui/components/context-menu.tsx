import { useLayoutEffect, useMemo } from "preact/hooks";
import { Icon } from "@/components/icon";
import { Menu, MenuItem, menuIconClass, MenuSeparator } from "@/components/ui/menu";

export type ContextMenuEntry =
  | {
      readonly kind: "item";
      readonly label: string;
      /** Sprite symbol name without the `i-` prefix. */
      readonly icon: string;
      readonly danger: boolean;
      /** Why the action is unavailable for this VM, or null when it is available. */
      readonly reason: string | null;
      readonly run: () => void;
    }
  | { readonly kind: "separator" };

export type ContextMenuRequest = {
  /** Distinguishes a reopened menu from the one it replaces, so focus lands on the new first item. */
  readonly id: number;
  /** Index of the VM row the menu belongs to; Escape hands focus back to that row. */
  readonly vmIndex: number;
  readonly x: number;
  readonly y: number;
  readonly entries: ReadonlyArray<ContextMenuEntry>;
};

/**
 * Right-click (or Shift+F10) menu for a VM row. A click anywhere outside closes it; the listener
 * attaches in a layout effect so a click right after the menu appears is already covered.
 */
export const ContextMenu = ({ request, onClose }: { readonly request: ContextMenuRequest; readonly onClose: () => void }) => {
  useLayoutEffect(() => {
    const controller = new AbortController();
    document.addEventListener(
      "click",
      (event) => {
        if (event.target instanceof Element && event.target.closest(".ctx-menu") === null) {
          onClose();
        }
      },
      { signal: controller.signal },
    );
    return () => controller.abort();
  }, [onClose]);

  const point = useMemo(() => ({ x: request.x, y: request.y }), [request.x, request.y]);
  return (
    <Menu key={request.id} label="VM actions" class="ctx-menu" open anchor={point} onSelect={onClose}>
      {request.entries.map((entry, index) => {
        if (entry.kind === "separator") {
          return <MenuSeparator key={`sep-${index}`} />;
        }
        return (
          <MenuItem
            key={entry.label}
            variant={entry.danger ? "danger" : "default"}
            tabIndex={-1}
            disabled={entry.reason !== null}
            title={entry.reason ?? undefined}
            onClick={entry.run}
          >
            <Icon name={entry.icon} class={menuIconClass(entry.danger)} />
            {entry.label}
          </MenuItem>
        );
      })}
    </Menu>
  );
};
