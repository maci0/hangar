import type { ComponentProps } from "preact";
import { useRef, useState } from "preact/hooks";

/** Pixels a touch must travel before it counts as a drag, so a tap still selects. */
const TOUCH_DRAG_THRESHOLD_PX = 8;
const GHOST_OFFSET_LEFT_PX = 8;
const GHOST_OPACITY = "0.85";
const GHOST_Z_INDEX = "9999";

type DragState = { readonly from: number; readonly over: number | null } | null;
type RowProps = ComponentProps<"div">;

export type Reorder = {
  /** The row being dragged and the row it would land on (`null` until it is over another row). */
  readonly drag: DragState;
  /** Event handlers that make the row at `index` draggable by mouse and by touch. */
  readonly rowProps: (index: number) => RowProps;
};

type Touch = {
  readonly from: number;
  readonly row: HTMLElement;
  readonly startY: number;
  readonly pointerId: number;
  ghost: HTMLElement | null;
};

const indexOfRow = (row: HTMLElement): number => Number(row.dataset.vmIndex);

/** The row under a vertical position: the first whose midpoint lies below it, else the last. */
const rowAt = (list: Element, y: number): HTMLElement | null => {
  const rows = [...list.querySelectorAll<HTMLElement>(".vm-item")];
  return rows.find((row) => y < row.getBoundingClientRect().top + row.getBoundingClientRect().height / 2) ?? rows.at(-1) ?? null;
};

/** A floating copy of the row that follows the finger. */
const makeGhost = (row: HTMLElement): HTMLElement => {
  const ghost = document.createElement("div");
  ghost.append(row.cloneNode(true));
  Object.assign(ghost.style, {
    position: "fixed",
    zIndex: GHOST_Z_INDEX,
    pointerEvents: "none",
    opacity: GHOST_OPACITY,
    width: `${row.offsetWidth}px`,
    boxShadow: "var(--shadow-lg)",
    background: "var(--surface)",
    borderRadius: "var(--radius-md)",
  });
  document.body.append(ghost);
  return ghost;
};

/** HTML5 drag and drop, which browsers run for a mouse (pure: it holds no state of its own). */
const mouseDragProps = (drag: DragState, setDrag: (next: DragState) => void, onReorder: (from: number, to: number) => void) =>
  (index: number): RowProps => ({
    draggable: true,
    onDragStart: (event) => {
      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move";
        // Firefox starts no drag without data.
        event.dataTransfer.setData("text/plain", "");
      }
      setDrag({ from: index, over: null });
    },
    onDragEnd: () => setDrag(null),
    onDragOver: (event) => {
      event.preventDefault();
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = "move";
      }
      if (drag !== null && drag.from !== index && drag.over !== index) {
        setDrag({ from: drag.from, over: index });
      }
    },
    onDragLeave: () => {
      if (drag?.over === index) {
        setDrag({ from: drag.from, over: null });
      }
    },
    onDrop: (event) => {
      event.preventDefault();
      setDrag(null);
      if (drag !== null && drag.from !== index) {
        onReorder(drag.from, index);
      }
    },
  });

/** Pointer events for touch and pen, which start no native drag. */
const useTouchDrag = (setDrag: (next: DragState) => void, onReorder: (from: number, to: number) => void) => {
  const touch = useRef<Touch | null>(null);
  const finish = (): void => {
    touch.current?.ghost?.remove();
    touch.current = null;
    setDrag(null);
  };
  const move = (event: PointerEvent, active: Touch): void => {
    if (active.ghost === null) {
      if (Math.abs(event.clientY - active.startY) < TOUCH_DRAG_THRESHOLD_PX) {
        return;
      }
      active.ghost = makeGhost(active.row);
    }
    active.ghost.style.left = `${GHOST_OFFSET_LEFT_PX}px`;
    active.ghost.style.top = `${event.clientY - active.ghost.offsetHeight / 2}px`;
    const list = active.row.closest("#vmlist");
    const target = list === null ? null : rowAt(list, event.clientY);
    const over = target === null ? Number.NaN : indexOfRow(target);
    setDrag({ from: active.from, over: Number.isNaN(over) || over === active.from ? null : over });
  };
  const drop = (event: PointerEvent, active: Touch): void => {
    const list = active.row.closest("#vmlist");
    const target = active.ghost !== null && list !== null ? rowAt(list, event.clientY) : null;
    finish();
    const to = target === null ? Number.NaN : indexOfRow(target);
    if (!Number.isNaN(to) && to !== active.from) {
      onReorder(active.from, to);
    }
  };
  const cancel = (event: PointerEvent): void => {
    if (event.pointerId === touch.current?.pointerId) {
      finish();
    }
  };
  return (index: number): RowProps => ({
    onPointerDown: (event) => {
      if (event.pointerType !== "mouse") {
        event.currentTarget.setPointerCapture(event.pointerId);
        touch.current = { from: index, row: event.currentTarget, startY: event.clientY, pointerId: event.pointerId, ghost: null };
      }
    },
    onPointerMove: (event) => {
      const active = touch.current;
      if (active?.pointerId === event.pointerId) {
        move(event, active);
      }
    },
    onPointerUp: (event) => {
      const active = touch.current;
      if (active?.pointerId === event.pointerId) {
        drop(event, active);
      }
    },
    onPointerCancel: cancel,
    onLostPointerCapture: cancel,
  });
};

/**
 * Drag-to-reorder for the sidebar rows: HTML5 drag and drop for a mouse, pointer events with a
 * floating copy of the row for touch and pen. `onReorder(from, to)\` receives list indexes.
 */
export const useReorder = (onReorder: (from: number, to: number) => void): Reorder => {
  const [drag, setDrag] = useState<DragState>(null);
  const mouse = mouseDragProps(drag, setDrag, onReorder);
  const touch = useTouchDrag(setDrag, onReorder);
  return { drag, rowProps: (index) => ({ ...mouse(index), ...touch(index) }) };
};
