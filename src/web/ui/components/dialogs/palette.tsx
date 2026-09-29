import { useEffect, useRef, useState } from "preact/hooks";
import { Icon } from "@/components/icon";
import { Dialog, useDialogClose } from "@/components/ui/dialog";
import { cn } from "@/lib/cn";

export type PaletteCommand = {
  readonly label: string;
  /** Sprite symbol name without the `i-` prefix. */
  readonly icon?: string;
  readonly run: () => void;
};

export type PaletteRequest = {
  readonly id: number;
  readonly commands: ReadonlyArray<PaletteCommand>;
};

const LIST_ID = "paletteList";
const optionId = (index: number): string => `paletteOpt${index}`;

const matching = (commands: ReadonlyArray<PaletteCommand>, query: string): ReadonlyArray<PaletteCommand> => {
  const needle = query.toLowerCase().trim();
  return needle === "" ? commands : commands.filter((command) => command.label.toLowerCase().includes(needle));
};

const PaletteOptions = ({ shown, selected, onPick }: {
  readonly shown: ReadonlyArray<PaletteCommand>;
  readonly selected: number;
  readonly onPick: (command: PaletteCommand) => void;
}) => {
  useEffect(() => {
    document.querySelector(`#${optionId(selected)}`)?.scrollIntoView({ block: "nearest" });
  }, [selected]);
  return (
    <ul id={LIST_ID} role="listbox" aria-label="Commands" class="m-0 max-h-96 list-none overflow-auto p-1">
      {shown.map((command, index) => (
        <li
          key={command.label}
          id={optionId(index)}
          role="option"
          data-pidx={index}
          aria-selected={index === selected}
          class={cn(
            "flex cursor-pointer items-center gap-2 rounded-sm border-l-2 border-transparent px-2.75 py-1.5 text-field text-fg-muted transition-colors",
            index === selected && "sel border-accent bg-accent-soft text-fg",
          )}
          onClick={() => onPick(command)}
        >
          {command.icon === undefined ? <span class="size-3.5 flex-none" aria-hidden="true" /> : <Icon name={command.icon} />}
          {command.label}
        </li>
      ))}
      {shown.length === 0 && <li class="palette-empty cursor-default px-2.75 py-1.5 text-field text-fg-dim">No matches</li>}
    </ul>
  );
};

const PaletteContent = ({ commands, onPick }: {
  readonly commands: ReadonlyArray<PaletteCommand>;
  readonly onPick: (command: PaletteCommand) => void;
}) => {
  const close = useDialogClose();
  const input = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const shown = matching(commands, query);

  useEffect(() => {
    input.current?.focus();
  }, []);

  const pick = (command: PaletteCommand | undefined) => {
    if (command !== undefined) {
      onPick(command);
      close();
    }
  };

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (shown.length > 0) {
        const step = event.key === "ArrowDown" ? 1 : -1;
        setSelected((selected + step + shown.length) % shown.length);
      }
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(shown[selected]);
    }
  };

  return (
    <>
      <h2 id="paletteTitle" class="sr-only">
        Command palette
      </h2>
      <input
        id="paletteInput"
        ref={input}
        type="text"
        class="empty-hint w-full border-0 border-b border-border bg-transparent px-3.5 py-3 text-title text-fg outline-none focus-visible:outline-2 focus-visible:-outline-offset-3 focus-visible:outline-fg"
        placeholder="Type a command or VM name…"
        aria-label="Command palette"
        role="combobox"
        aria-expanded="true"
        aria-controls={LIST_ID}
        aria-autocomplete="list"
        aria-activedescendant={shown.length > 0 ? optionId(selected) : undefined}
        autocomplete="off"
        value={query}
        onInput={(event) => {
          setQuery(event.currentTarget.value);
          setSelected(0);
        }}
        onKeyDown={onKeyDown}
      />
      <PaletteOptions shown={shown} selected={selected} onPick={pick} />
    </>
  );
};

/**
 * Ctrl+K launcher: filters commands by label as you type; Arrow keys move, Enter or a click runs
 * one. The chosen command runs after the palette has closed, so a dialog it opens keeps focus.
 */
export const PaletteDialog = ({ request, onClose }: { readonly request: PaletteRequest; readonly onClose: () => void }) => {
  const picked = useRef<PaletteCommand | null>(null);
  return (
    <Dialog
      key={request.id}
      id="palette"
      titleId="paletteTitle"
      class="mt-24 mb-auto w-135"
      onClose={() => {
        onClose();
        picked.current?.run();
      }}
    >
      <PaletteContent
        commands={request.commands}
        onPick={(command) => {
          picked.current = command;
        }}
      />
    </Dialog>
  );
};
